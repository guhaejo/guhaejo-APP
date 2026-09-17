import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'supabase_client.dart';

class ItemsResult {
  final List<LostItem> items;
  final int total;
  final int page;
  final int totalPages;

  const ItemsResult({
    required this.items,
    required this.total,
    required this.page,
    required this.totalPages,
  });
}

const _foundItemSelect = '*, profiles!found_items_finder_id_fkey(id, name, avatar), quizzes(id, question, type, options)';
const _lostReportSelect = '*, profiles!lost_items_owner_id_fkey(id, name, avatar)';

class ItemsService {
  Future<ItemsResult> fetchItems({
    String? category,
    String? search,
    List<String>? locationKeywords,
    int page = 1,
    int limit = 20,
  }) async {
    final offset = (page - 1) * limit;

    var query = supabase
        .from('found_items')
        .select(_foundItemSelect)
        .eq('status', 'available');

    if (category != null && category.isNotEmpty) {
      query = query.eq('category', category);
    }
    if (search != null && search.isNotEmpty) {
      final term = _escapeLike(search);
      query = query.or(
        'title.ilike.%$term%,description.ilike.%$term%,location.ilike.%$term%',
      );
    }
    if (locationKeywords != null && locationKeywords.isNotEmpty) {
      final clause = locationKeywords
          .map((k) => _escapeLike(k))
          .map((k) => 'location.ilike.%$k%,description.ilike.%$k%')
          .join(',');
      query = query.or(clause);
    }

    final res = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1)
        .count(CountOption.exact);

    final rawItems = res.data;
    final total = res.count;

    return ItemsResult(
      items: rawItems.map(_lostItemFromJson).toList(),
      total: total,
      page: page,
      totalPages: (total / limit).ceil().clamp(1, 1 << 30),
    );
  }

  Future<List<LostItem>> fetchRecent({int limit = 5}) async {
    final result = await fetchItems(limit: limit);
    return result.items;
  }

  Future<List<LostItem>> fetchMine() async {
    final uid = _requireUid();
    final data = await supabase
        .from('found_items')
        .select(_foundItemSelect)
        .eq('finder_id', uid)
        .order('created_at', ascending: false);
    return (data as List).map((json) => _lostItemFromJson(json as Map<String, dynamic>)).toList();
  }

  Future<List<LostItem>> fetchFavorites() async {
    final uid = _requireUid();
    final data = await supabase
        .from('favorites')
        .select('found_items($_foundItemSelect)')
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    return (data as List)
        .map((row) => _lostItemFromJson((row as Map<String, dynamic>)['found_items'] as Map<String, dynamic>))
        .toList();
  }

  Future<bool> toggleFavorite(String itemId) async {
    final uid = _requireUid();
    final existing = await supabase
        .from('favorites')
        .select('id')
        .eq('user_id', uid)
        .eq('found_item_id', itemId)
        .maybeSingle();

    if (existing != null) {
      await supabase.from('favorites').delete().eq('id', existing['id'] as String);
      return false;
    }

    await supabase.from('favorites').insert({'user_id': uid, 'found_item_id': itemId});
    return true;
  }

  Future<LostItem> createFoundItem({
    required String category,
    required String title,
    required String description,
    required String location,
    required List<Map<String, dynamic>> quizzes,
    double mapX = 0,
    double mapY = 0,
    String? imageUrl,
  }) async {
    final data = await supabase.rpc('create_found_item', params: {
      'p_category': category,
      'p_title': title,
      'p_description': description,
      'p_location': location,
      'p_map_x': mapX,
      'p_map_y': mapY,
      'p_image_url': imageUrl,
      'p_quizzes': _normalizeQuizzes(quizzes),
    }) as Map<String, dynamic>;

    return _lostItemFromJson(data);
  }

  Future<void> deleteFoundItem(String id) async {
    final uid = _requireUid();
    final owned = await supabase.from('found_items').select('finder_id').eq('id', id).maybeSingle();
    if (owned == null) throw const AppException('아이템을 찾을 수 없습니다.');
    if (owned['finder_id'] != uid) throw const AppException('권한이 없습니다.');

    await supabase.from('found_items').delete().eq('id', id);
  }

  Future<LostItem> updateFoundItem({
    required String id,
    required String category,
    required String title,
    required String description,
    required String location,
    required List<Map<String, dynamic>> quizzes,
    double mapX = 0,
    double mapY = 0,
    String? imageUrl,
  }) async {
    final uid = _requireUid();
    final owned = await supabase.from('found_items').select('finder_id').eq('id', id).maybeSingle();
    if (owned == null) throw const AppException('아이템을 찾을 수 없습니다.');
    if (owned['finder_id'] != uid) throw const AppException('권한이 없습니다.');

    await supabase.from('found_items').update({
      'category': category,
      'title': title,
      'description': description,
      'location': location,
      'map_x': mapX,
      'map_y': mapY,
      if (imageUrl != null) 'image_url': imageUrl,
    }).eq('id', id);

    await supabase.from('quizzes').delete().eq('found_item_id', id);
    await supabase.from('quizzes').insert(
      _normalizeQuizzes(quizzes)
          .map((q) => {
                'found_item_id': id,
                'question': q['question'],
                'type': q['type'],
                'options': q['options'],
                'correct_answer': q['correctAnswer'],
              })
          .toList(),
    );

    final refreshed = await supabase.from('found_items').select(_foundItemSelect).eq('id', id).single();
    return _lostItemFromJson(refreshed);
  }

  /// 수정화면 프리필용 — 본인 아이템의 퀴즈를 정답 포함으로 조회
  Future<List<Quiz>> fetchMyItemQuizzesWithAnswers(String foundItemId) async {
    final data = await supabase.rpc('get_my_item_quizzes', params: {'p_found_item_id': foundItemId});
    return _quizzesFromJson(data);
  }

  // ---------------------------------------------------------------------
  // 분실 신고 (lost_items)
  // ---------------------------------------------------------------------

  Future<LostReport> createLostItem({
    required String category,
    required String title,
    required String description,
    required String location,
    String? imageUrl,
    String? reward,
    int bountyPoints = 0,
  }) async {
    final data = await supabase.rpc('create_lost_item', params: {
      'p_category': category,
      'p_title': title,
      'p_description': description,
      'p_location': location,
      'p_image_url': imageUrl,
      'p_reward': reward,
      'p_bounty_points': bountyPoints,
    }) as Map<String, dynamic>;

    return _lostReportFromJson(data);
  }

  Future<List<LostReport>> fetchPublicLostReports({
    String? category,
    String? search,
    int limit = 20,
  }) async {
    var query = supabase
        .from('lost_items')
        .select(_lostReportSelect)
        .eq('status', 'searching');

    if (category != null && category.isNotEmpty) {
      query = query.eq('category', category);
    }
    if (search != null && search.isNotEmpty) {
      query = query.ilike('title', '%$search%');
    }

    final data = await query.order('created_at', ascending: false).limit(limit);
    return (data as List)
        .map((json) => _lostReportFromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<LostReport>> fetchMyLostReports() async {
    final uid = _requireUid();
    final data = await supabase
        .from('lost_items')
        .select(_lostReportSelect)
        .eq('owner_id', uid)
        .order('created_at', ascending: false);
    return (data as List)
        .map((json) => _lostReportFromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<void> cancelLostReport(String id) async {
    await supabase.rpc('cancel_lost_item', params: {'p_lost_item_id': id});
  }

  Future<void> deleteLostReport(String id) async {
    await supabase.rpc('delete_lost_item', params: {'p_lost_item_id': id});
  }

  Future<void> resolveLostReport(String id, String finderId) async {
    await supabase.rpc('resolve_lost_item', params: {
      'p_lost_item_id': id,
      'p_finder_id': finderId,
    });
  }

  LostReport _lostReportFromJson(Map<String, dynamic> json) {
    final profile = json['profiles'] is Map<String, dynamic>
        ? json['profiles'] as Map<String, dynamic>
        : null;

    return LostReport(
      id: json['id'] as String,
      category: json['category'] as String? ?? 'etc',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      imageUrl: json['image_url'] as String?,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      location: json['location'] as String? ?? '',
      status: json['status'] as String? ?? 'searching',
      reward: json['reward'] as String?,
      bountyPoints: (json['bounty_points'] as num?)?.toInt() ?? 0,
      ownerId: json['owner_id'] as String? ?? '',
      ownerName: profile?['name'] as String?,
      matchedFinderId: json['matched_finder_id'] as String?,
    );
  }

  List<Map<String, dynamic>> _normalizeQuizzes(List<Map<String, dynamic>> quizzes) {
    return quizzes
        .map(
          (quiz) => {
            'question': quiz['question'],
            'type': quiz['type'] ?? 'text',
            'options': quiz['options'],
            'correctAnswer': quiz['correctAnswer'],
          },
        )
        .toList();
  }

  /// ilike 패턴(%, _)과 or() 필터 구분자(,)를 이스케이프해서
  /// 사용자 입력을 안전하게 검색어로 쓸 수 있게 한다.
  String _escapeLike(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_')
        .replaceAll(',', ' ')
        .trim();
  }

  String _requireUid() {
    final uid = currentUserId;
    if (uid == null) throw const AppException('로그인이 필요합니다.');
    return uid;
  }

  LostItem _lostItemFromJson(Map<String, dynamic> json) {
    final profile = json['profiles'] is Map<String, dynamic>
        ? json['profiles'] as Map<String, dynamic>
        : null;

    return LostItem(
      id: json['id'] as String,
      category: json['category'] as String? ?? 'etc',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      imageUrl: json['image_url'] as String?,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      quizzes: _quizzesFromJson(json['quizzes']),
      finderId: json['finder_id'] as String? ?? profile?['id'] as String?,
      foundBy: profile?['name'] as String?,
      location: json['location'] as String? ?? '',
      mapPos: MapPos(
        x: _numToDouble(json['map_x']),
        y: _numToDouble(json['map_y']),
      ),
    );
  }

  List<Quiz> _quizzesFromJson(dynamic value) {
    if (value is! List) return const [];

    return value.map((item) {
      final json = item as Map<String, dynamic>;
      final options = json['options'];
      return Quiz(
        id: json['id'] as String?,
        question: json['question'] as String? ?? '',
        type: json['type'] as String? ?? 'text',
        options: options is List ? options.map((v) => '$v').toList() : null,
        correctAnswer: json['correct_answer'],
      );
    }).toList();
  }

  double _numToDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }
}
