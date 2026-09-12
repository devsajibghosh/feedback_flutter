/// A negative-feedback reason category, as returned by
/// `POST /admin/get-categories` (§5).
class Category {
  const Category({required this.id, required this.name});

  final int id;
  final String name;

  factory Category.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    return Category(
      id: id is int ? id : int.parse(id.toString()),
      name: json['name']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}
