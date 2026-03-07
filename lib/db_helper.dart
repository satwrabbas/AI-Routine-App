import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDBHelper {
  
  static final LocalDBHelper _instance = LocalDBHelper._internal();
  factory LocalDBHelper() => _instance;
  LocalDBHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  
  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'ai_planner.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  
  Future _onCreate(Database db, int version) async {
    
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

    
    await db.execute('''
      CREATE TABLE deleted_tasks_queue (
        id TEXT PRIMARY KEY
      )
    ''');
  }

  
  
  

  
  
  Future<void> upsertTask(Map<String, dynamic> task) async {
    final db = await database;
    
    
    
    if (!task.containsKey('is_synced')) {
      task['is_synced'] = 0; 
    }

    
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

  
  Future<void> deleteTask(String id) async {
    final db = await database;
    
    
    await db.delete(
      'tasks',
      where: 'id = ?',
      whereArgs: [id],
    );

    
    await db.insert(
      'deleted_tasks_queue',
      {'id': id},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  
  
  

  
  Future<List<Map<String, dynamic>>> getUnsyncedTasks() async {
    final db = await database;
    return await db.query(
      'tasks',
      where: 'is_synced = ?',
      whereArgs: [0],
    );
  }

  
  
  Future<void> markTaskAsSynced(String id) async {
    final db = await database;
    await db.update(
      'tasks',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  
  Future<List<String>> getDeletedTasksQueue() async {
    final db = await database;
    final result = await db.query('deleted_tasks_queue');
    return result.map((e) => e['id'] as String).toList();
  }

  
  Future<void> removeFromDeletedQueue(String id) async {
    final db = await database;
    await db.delete(
      'deleted_tasks_queue',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
  
  
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('tasks');
    await db.delete('deleted_tasks_queue');
  }
}