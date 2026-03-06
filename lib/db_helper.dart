import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDBHelper {
  // Singleton Pattern
  static final LocalDBHelper _instance = LocalDBHelper._internal();
  factory LocalDBHelper() => _instance;
  LocalDBHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  // تهيئة قاعدة البيانات
  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'ai_planner.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  // إنشاء الجداول
  Future _onCreate(Database db, int version) async {
    // جدول المهام الأساسي
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        scheduled_time TEXT NOT NULL,
        is_completed INTEGER NOT NULL DEFAULT 0,
        is_synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // جدول لتخزين معرفات المهام المحذوفة (لأجل المزامنة لاحقاً)
    await db.execute('''
      CREATE TABLE deleted_tasks_queue (
        id TEXT PRIMARY KEY
      )
    ''');
  }

  // ----------------------------------------------------------------
  // CRUD Operations (Create, Read, Update, Delete)
  // ----------------------------------------------------------------

  // 1. إضافة مهمة جديدة (أو تحديثها إذا كانت موجودة - Upsert)
  // نستخدم ConflictAlgorithm.replace لاستبدال البيانات إذا كان الـ ID مكرراً
  Future<void> upsertTask(Map<String, dynamic> task) async {
    final db = await database;
    
    // تأكد من أن الحالة هي "غير متزامن" (0) عند التعديل المحلي
    // إلا إذا قمنا بتمرير is_synced=1 صراحة (في حالة التحميل من السيرفر)
    if (!task.containsKey('is_synced')) {
      task['is_synced'] = 0; 
    }

    // تحويل البوليان إلى Integer لأن SQLite لا يدعم boolean
    int isCompletedInt = (task['is_completed'] == true || task['is_completed'] == 1) ? 1 : 0;
    
    await db.insert(
      'tasks',
      {
        'id': task['id'],
        'user_id': task['user_id'],
        'title': task['title'],
        'scheduled_time': task['scheduled_time'],
        'is_completed': isCompletedInt,
        'is_synced': task['is_synced'], 
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // 2. جلب جميع المهام (للعرض في الواجهة)
  // نرتبها حسب الوقت
  Future<List<Map<String, dynamic>>> getTasks(String userId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'tasks',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'scheduled_time ASC',
    );
    return maps;
  }

  // 3. حذف مهمة
  Future<void> deleteTask(String id) async {
    final db = await database;
    
    // أولاً: نحذفها من جدول المهام
    await db.delete(
      'tasks',
      where: 'id = ?',
      whereArgs: [id],
    );

    // ثانياً: نضيف المعرف إلى طابور المحذوفات لنخبر السيرفر بحذفها لاحقاً
    await db.insert(
      'deleted_tasks_queue',
      {'id': id},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ----------------------------------------------------------------
  // Sync Helper Methods (طرق مساعدة للمزامنة)
  // ----------------------------------------------------------------

  // جلب المهام التي لم يتم مزامنتها بعد (is_synced = 0)
  Future<List<Map<String, dynamic>>> getUnsyncedTasks() async {
    final db = await database;
    return await db.query(
      'tasks',
      where: 'is_synced = ?',
      whereArgs: [0],
    );
  }

  // تحديث حالة المهمة لتصبح "متزامنة" (is_synced = 1)
  // يتم استدعاء هذه الدالة بعد نجاح الرفع إلى Supabase
  Future<void> markTaskAsSynced(String id) async {
    final db = await database;
    await db.update(
      'tasks',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // جلب معرفات المهام التي يجب حذفها من السيرفر
  Future<List<String>> getDeletedTasksQueue() async {
    final db = await database;
    final result = await db.query('deleted_tasks_queue');
    return result.map((e) => e['id'] as String).toList();
  }

  // تنظيف طابور المحذوفات بعد نجاح الحذف من السيرفر
  Future<void> removeFromDeletedQueue(String id) async {
    final db = await database;
    await db.delete(
      'deleted_tasks_queue',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
  
  // دالة لحذف كامل البيانات (عند تسجيل الخروج)
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('tasks');
    await db.delete('deleted_tasks_queue');
  }
}