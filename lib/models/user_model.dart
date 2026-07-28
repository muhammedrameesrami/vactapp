class UserModel {
  final String uid;
  final String name;
  final String email;
  final String phone;
  final int? age;
  final String? gender;
  final DateTime createdAt;

  /// FCM push-notification tokens for this user.
  /// Stored as a list so the same account can receive notifications on
  /// multiple devices simultaneously.
  final List<String> fcmTokens;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    this.age,
    this.gender,
    required this.createdAt,
    List<String>? fcmTokens,
  }) : fcmTokens = fcmTokens ?? const [];

  /// Converts the model to a Map suitable for Firestore.
  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'phone': phone,
      'age': age,
      'gender': gender,
      'createdAt': createdAt.toIso8601String(),
      'fcmTokens': fcmTokens,
    };
  }

  /// Creates a [UserModel] from a Firestore document snapshot map.
  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      phone: map['phone'] as String? ?? '',
      age: map['age'] as int?,
      gender: map['gender'] as String?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      fcmTokens: List<String>.from(map['fcmTokens'] ?? []),
    );
  }

  @override
  String toString() =>
      'UserModel(uid: $uid, name: $name, email: $email, phone: $phone, '
      'age: $age, gender: $gender, createdAt: $createdAt, '
      'fcmTokens: $fcmTokens)';
}
