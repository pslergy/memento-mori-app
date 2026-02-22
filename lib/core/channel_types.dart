// Типы и фильтры каналов. Интеграция с бэкендом: значения передаются в API.

/// Тип канала при создании и в списке.
class ChannelType {
  const ChannelType(this.id, this.labelEn, this.labelRu);
  final String id;
  final String labelEn;
  final String labelRu;
  @override
  String toString() => id;
}

const List<ChannelType> kChannelTypes = [
  ChannelType('news', 'News', 'Новости'),
  ChannelType('entertainment', 'Entertainment', 'Развлечения'),
  ChannelType('tech', 'Tech', 'Технологии'),
  ChannelType('education', 'Education', 'Образование'),
  ChannelType('lifestyle', 'Lifestyle', 'Стиль жизни'),
  ChannelType('sports', 'Sports', 'Спорт'),
  ChannelType('other', 'Other', 'Другое'),
];

/// Варианты сортировки/фильтра при поиске каналов (тематика, популярность).
class ChannelSortOption {
  const ChannelSortOption(this.id, this.labelEn, this.labelRu);
  final String id;
  final String labelEn;
  final String labelRu;
}

const List<ChannelSortOption> kChannelSortOptions = [
  ChannelSortOption('popular', 'Most popular', 'Самые популярные'),
  ChannelSortOption('newest', 'Newest', 'Новые'),
  ChannelSortOption('subscribers', 'By subscribers', 'По подписчикам'),
  ChannelSortOption('thematic', 'Thematic', 'Тематические'),
];

/// Ключи SharedPreferences для сохранения фильтров на стороне пользователя.
const String kPrefChannelFilterCategory = 'channel_filter_category';
const String kPrefChannelFilterSort = 'channel_filter_sort';
