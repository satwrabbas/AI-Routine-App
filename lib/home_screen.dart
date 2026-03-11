import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart'; 
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'db_helper.dart';
import 'notification_service.dart';
import 'auth_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'routines_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  
  final LocalDBHelper _dbHelper = LocalDBHelper();
  final NotificationService _notificationService = NotificationService();
  final SupabaseClient _supabase = Supabase.instance.client;
  
  

  final String _geminiApiKey = dotenv.env['GEMINI_API_KEY']!; 
  late final GenerativeModel _geminiModel;

  List<Map<String, dynamic>> _tasks = [];
  bool _isLoading = false; 

  @override
  void initState() {
    super.initState();
    
    _geminiModel = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: _geminiApiKey,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json', 
      ),
    );

    _loadLocalData(); 
    _syncData();      
  }

  
  
  // دالة إعادة الجدولة الديناميكية
  Future<void> _rescheduleUncompletedTasks() async {
    // 1. جلب المهام غير المكتملة فقط
    final uncompletedTasks = _tasks.where((t) => t['is_completed'] == 0).toList();
    
    if (uncompletedTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد مهام غير مكتملة لإعادة جدولتها!')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final now = DateTime.now();
      
      // تحويل المهام الحالية لنص ليفهمها الذكاء الاصطناعي
      final tasksJsonString = jsonEncode(uncompletedTasks.map((t) => {
        "id": t['id'],
        "title": t['title'],
        "old_time": t['scheduled_time']
      }).toList());

      // Prompt Engineering لإعادة الجدولة
      final prompt = '''
      You are a strict JSON generator.
      The user missed their schedule. The CURRENT EXACT TIME is ${now.toIso8601String()}.
      Here is the list of their uncompleted tasks:
      $tasksJsonString
      
      Please reschedule these tasks to start AFTER the current time, distributing them logically for the rest of the day.
      Keep the EXACT SAME "id" and "title" for each task, only change the "scheduled_time".
      Format: JSON Array of objects with keys: "id" (string), "title" (string), "scheduled_time" (ISO 8601 string).
      Do NOT include any markdown or plain text. Just the JSON array.
      ''';

      final content =[Content.text(prompt)];
      final response = await _geminiModel.generateContent(content);

      if (response.text != null) {
        String cleanedJson = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
        List<dynamic> rescheduledTasksJson = jsonDecode(cleanedJson);

        for (var updatedTask in rescheduledTasksJson) {
          // 2. تحديث كل مهمة في Local Database
          final taskId = updatedTask['id'];
          final newTime = DateTime.parse(updatedTask['scheduled_time']);
          
          final existingTaskIndex = _tasks.indexWhere((t) => t['id'] == taskId);
          if (existingTaskIndex != -1) {
            var taskToUpdate = Map<String, dynamic>.from(_tasks[existingTaskIndex]);
            taskToUpdate['scheduled_time'] = newTime.toIso8601String();
            taskToUpdate['is_synced'] = 0; // لنجبر المزامنة مع السيرفر

            await _dbHelper.upsertTask(taskToUpdate);

            // 3. إلغاء الإشعار القديم وجدولة الجديد
            await _notificationService.cancelNotification(taskId);
            await _notificationService.scheduleTaskNotification(
              taskId: taskId,
              title: taskToUpdate['title'],
              scheduledTime: newTime,
            );
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تمت إعادة جدولة مهامك بذكاء! 🪄')),
        );

        // 4. تحديث الواجهة ورفع التغييرات للسيرفر
        _loadLocalData();
        _syncData();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل في إعادة الجدولة: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  
  Future<void> _loadLocalData() async {
    final userId = _supabase.auth.currentUser!.id;
    final data = await _dbHelper.getTasks(userId);
    setState(() {
      _tasks = data;
    });
  }

  
  Future<void> _syncData() async {
    final userId = _supabase.auth.currentUser!.id;

    
    // --- الجديد: مزامنة الروتينات أولاً (Upsert Routines) ---
    final unsyncedRoutines = await _dbHelper.getUnsyncedRoutines();
    for (var routine in unsyncedRoutines) {
      final routineForServer = Map<String, dynamic>.from(routine);
      routineForServer.remove('is_synced'); // تنظيف قبل الرفع

      try {
        await _supabase.from('routines').upsert(routineForServer);
        await _dbHelper.markRoutineAsSynced(routine['id']);
      } catch (e) {
        debugPrint("فشل مزامنة الروتين: $e");
      }
    }
    
    final deletedIds = await _dbHelper.getDeletedTasksQueue();
    if (deletedIds.isNotEmpty) {
      
      
      final idsString = '(${deletedIds.map((e) => '"$e"').join(',')})';
      
      
      await _supabase
          .from('tasks')
          .delete()
          .filter('id', 'in', idsString); 
      
      for (var id in deletedIds) {
        await _dbHelper.removeFromDeletedQueue(id);
      }
    }

    
    final unsyncedTasks = await _dbHelper.getUnsyncedTasks();
    for (var task in unsyncedTasks) {
      
      final taskForServer = {
        ...task,
        'is_completed': task['is_completed'] == 1,
        
        'is_synced': null 
      };
      taskForServer.remove('is_synced'); 

      await _supabase.from('tasks').upsert(taskForServer);
      await _dbHelper.markTaskAsSynced(task['id']);
    }

    
    try {
      final remoteData = await _supabase
          .from('tasks')
          .select()
          .eq('user_id', userId); 

      for (var remoteTask in remoteData) {
        
        final localTask = {
          'id': remoteTask['id'],
          'user_id': remoteTask['user_id'],
          'title': remoteTask['title'],
          'scheduled_time': remoteTask['scheduled_time'], 
          'is_completed': remoteTask['is_completed'] == true ? 1 : 0,
          'is_synced': 1, 
        };
        await _dbHelper.upsertTask(localTask);
        
        
        if (localTask['is_completed'] == 0) {
          _notificationService.scheduleTaskNotification(
            taskId: localTask['id'],
            title: localTask['title'],
            scheduledTime: DateTime.parse(localTask['scheduled_time']),
          );
        }
      }
      
      
      _loadLocalData();
      
    } catch (e) {
      
      debugPrint("Sync failed (Offline mode): $e");
    }
  }

  
  
  

  // استبدل دالة _addTask الحالية بالكامل بهذا الكود:
  Future<void> _addTask(String title, DateTime time, {String? routineId}) async {
    final newId = const Uuid().v4(); 
    final userId = _supabase.auth.currentUser!.id;

    final newTask = {
      'id': newId,
      'user_id': userId,
      'routine_id': routineId, // الآن الدالة تتعرف عليه بشكل صحيح
      'title': title,
      'scheduled_time': time.toIso8601String(),
      'is_completed': 0, 
      'is_synced': 0, 
    };

    // 1. حفظ محلي
    await _dbHelper.upsertTask(newTask);
    
    // 2. جدولة إشعار
    await _notificationService.scheduleTaskNotification(
      taskId: newId,
      title: title,
      scheduledTime: time,
    );

    // 3. تحديث واجهة
    _loadLocalData();

    // 4. محاولة مزامنة صامتة (Fire and Forget)
    _syncData(); 
  }

  
  Future<void> _editTask(String id, String newTitle, DateTime newTime) async {
    final index = _tasks.indexWhere((t) => t['id'] == id);
    if (index == -1) return;

    var updatedTask = Map<String, dynamic>.from(_tasks[index]);
    updatedTask['title'] = newTitle;
    updatedTask['scheduled_time'] = newTime.toIso8601String();
    updatedTask['is_synced'] = 0; 

    
    await _dbHelper.upsertTask(updatedTask);
    
    
    await _notificationService.cancelNotification(id);
    if (updatedTask['is_completed'] == 0) { 
      await _notificationService.scheduleTaskNotification(
        taskId: id,
        title: newTitle,
        scheduledTime: newTime,
      );
    }

    
    _loadLocalData();
    _syncData();
  }

  Future<void> _toggleTaskCompletion(String id, bool? value) async {
    final index = _tasks.indexWhere((t) => t['id'] == id);
    if (index == -1) return;

    var updatedTask = Map<String, dynamic>.from(_tasks[index]);
    updatedTask['is_completed'] = (value == true) ? 1 : 0;
    updatedTask['is_synced'] = 0; 

    await _dbHelper.upsertTask(updatedTask);
    
    
    if (value == true) {
      await _notificationService.cancelNotification(id);
    }

    _loadLocalData();
    _syncData();
  }

  Future<void> _deleteTask(String id) async {
    await _dbHelper.deleteTask(id); 
    await _notificationService.cancelNotification(id);
    _loadLocalData();
    _syncData();
  }

  
  
  

  Future<void> _generateRoutine(String goal) async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      
      
      final prompt = '''
      You are a strict JSON generator. 
      Create a daily routine for a user whose goal is: "$goal".
      The current time is ${now.toIso8601String()}.
      Generate 3 to 5 tasks starting AFTER the current time.
      Format: JSON Array of objects with keys: "title" (string), "scheduled_time" (ISO 8601 string).
      Example: [{"title": "Morning Run", "scheduled_time": "2024-01-01T07:00:00.000"}]
      Do NOT include any markdown ```json``` or plain text. Just the array.
      ''';

      final content = [Content.text(prompt)];
      final response = await _geminiModel.generateContent(content);

      if (response.text != null) {
        String cleanedJson = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
        List<dynamic> tasksJson = jsonDecode(cleanedJson);

        // 1. إنشاء سجل الروتين (Routine Record)
        final String newRoutineId = const Uuid().v4();
        final routineRecord = {
          'id': newRoutineId,
          'user_id': _supabase.auth.currentUser!.id,
          'title': 'روتين: $goal',
          'ai_prompt': goal,
          'is_synced': 0, // لنجبر المزامنة مع السيرفر
        };
        
        await _dbHelper.upsertRoutine(routineRecord);

        // 2. إضافة المهام وربطها بمعرف الروتين
        for (var t in tasksJson) {
          await _addTask(
            t['title'], 
            DateTime.parse(t['scheduled_time']),
            routineId: newRoutineId // ربط المهمة بالروتين
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل في توليد الروتين: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  
  Future<void> _signOut() async {
    await _dbHelper.clearAllData(); 
    await _notificationService.cancelAll();
    await _supabase.auth.signOut();
    
  }


  void _showTaskBottomSheet({Map<String, dynamic>? existingTask}) {
    final bool isEdit = existingTask != null;
    final titleController = TextEditingController(text: isEdit ? existingTask['title'] : '');
    
    
    TimeOfDay selectedTime = isEdit 
        ? TimeOfDay.fromDateTime(DateTime.parse(existingTask['scheduled_time']))
        : TimeOfDay.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B), 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20, right: 20, top: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children:[
                  Text(
                    isEdit ? 'تعديل المهمة' : 'إضافة مهمة يدوياً',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  
                  
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'عنوان المهمة...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.3),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: Colors.black.withOpacity(0.3),
                    leading: const Icon(Icons.access_time, color: Color(0xFF6366F1)),
                    title: const Text('وقت التنبيه', style: TextStyle(color: Colors.white)),
                    trailing: Text(
                      selectedTime.format(context),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    onTap: () async {
                      final TimeOfDay? picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime,
                      );
                      if (picked != null) {
                        setModalState(() => selectedTime = picked);
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  
                  
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        if (titleController.text.trim().isEmpty) return;
                        
                        
                        final now = DateTime.now();
                        DateTime scheduledDateTime = DateTime(
                          now.year, now.month, now.day, 
                          selectedTime.hour, selectedTime.minute
                        );

                        
                        if (scheduledDateTime.isBefore(now)) {
                          scheduledDateTime = scheduledDateTime.add(const Duration(days: 1));
                        }

                        if (isEdit) {
                          _editTask(existingTask['id'], titleController.text.trim(), scheduledDateTime);
                        } else {
                          _addTask(titleController.text.trim(), scheduledDateTime);
                        }
                        
                        Navigator.pop(context);
                      },
                      child: Text(isEdit ? 'تحديث' : 'حفظ', style: const TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }
  
  
  

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      
      // -- القائمة الجانبية الجديدة --
      drawer: Drawer(
        backgroundColor: const Color(0xFF1E293B),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors:[Color(0xFF6366F1), Color(0xFF312E81)]),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: const[
                  Icon(Icons.account_circle, size: 60, color: Colors.white),
                  SizedBox(height: 10),
                  Text('إدارة الروتينات', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.library_books, color: Colors.white),
              title: const Text('مكتبة الروتينات', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context); // إغلاق القائمة الجانبية
                
                // الانتقال للشاشة وانتظار النتيجة
                final bool? shouldRefresh = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const RoutinesScreen()),
                );
                
                // إذا قام المستخدم بتطبيق روتين، نحدث الشاشة والمزامنة
                if (shouldRefresh == true) {
                  _loadLocalData();
                  _syncData();
                }
              },
            ),
          ],
        ),
      ),
      // --------------------------------
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('AI Routine Planner'),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withOpacity(0.2)),
          ),
        ),
        actions:[
          // الزر السحري لإعادة الجدولة
          IconButton(
            tooltip: 'إعادة جدولة المهام المتأخرة',
            icon: const Icon(Icons.auto_fix_high, color: Color(0xFFEC4899)), // لون وردي مميز
            onPressed: () {
              // إظهار نافذة تأكيد قبل العملية
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1E293B),
                  title: const Text('عصا سحرية 🪄', style: TextStyle(color: Colors.white)),
                  content: const Text(
                    'هل تأخرت عن جدولك؟ سأقوم بإعادة ترتيب جميع مهامك غير المكتملة بناءً على الوقت الحالي.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  actions:[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEC4899)),
                      onPressed: () {
                        Navigator.pop(context);
                        _rescheduleUncompletedTasks();
                      },
                      child: const Text('إعادة جدولة', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
            },
          ),
          // زر الإضافة اليدوية
          IconButton(
            tooltip: 'إضافة مهمة',
            icon: const Icon(Icons.add_task),
            onPressed: () => _showTaskBottomSheet(), 
          ),
          // زر تسجيل الخروج
          IconButton(
            tooltip: 'خروج',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          )
        ],
      ),
      body: Stack(
        children: [
          
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0F172A), Color(0xFF1E1B4B)],
              ),
            ),
          ),
          
          
          Positioned(
            top: 100, right: -50,
            child: _buildBlurCircle(Colors.purple),
          ),
          Positioned(
            bottom: 100, left: -50,
            child: _buildBlurCircle(Colors.blueAccent),
          ),

          
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _tasks.isEmpty
                  ? Center(
                      child: Text(
                        'لا توجد مهام.\nاضغط على الزر السحري لإنشاء روتين!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withOpacity(0.7)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 100, 16, 80),
                      itemCount: _tasks.length,
                      itemBuilder: (context, index) {
                        final task = _tasks[index];
                        final date = DateTime.parse(task['scheduled_time']);
                        final isCompleted = task['is_completed'] == 1;

                        return Dismissible(
                          key: Key(task['id']),
                          background: Container(color: Colors.red),
                          onDismissed: (direction) => _deleteTask(task['id']),
                          child: _buildGlassTaskCard(task, date, isCompleted),
                        );
                      },
                    ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showGenerateDialog(),
        backgroundColor: const Color(0xFF6366F1),
        icon: const Icon(Icons.auto_awesome, color: Colors.white),
        label: const Text("توليد روتين AI", style: TextStyle(color: Colors.white)),
      ),
    );
  }

  
  Widget _buildGlassTaskCard(Map<String, dynamic> task, DateTime date, bool isCompleted) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: ListTile(
              leading: Checkbox(
                value: isCompleted,
                onChanged: (val) => _toggleTaskCompletion(task['id'], val),
                activeColor: const Color(0xFFEC4899),
                side: const BorderSide(color: Colors.white54),
              ),
              title: Text(
                task['title'],
                style: TextStyle(
                  color: Colors.white,
                  decoration: isCompleted ? TextDecoration.lineThrough : null,
                  decorationColor: Colors.white54,
                ),
              ),
              subtitle: Text(
                DateFormat('hh:mm a').format(date),
                style: TextStyle(color: Colors.white.withOpacity(0.6)),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children:[
                  
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, color: Colors.white54),
                    onPressed: () => _showTaskBottomSheet(existingTask: task), 
                  ),
                  
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white54),
                    onPressed: () => _deleteTask(task['id']),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  
  void _showGenerateDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('صمم يومك بالذكاء الاصطناعي', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'مثال: أريد أن أكون منتجاً وأتعلم البرمجة',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
          ),
        ),
        actions: [
          TextButton(
            child: const Text('إلغاء'),
            onPressed: () => Navigator.pop(context),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            child: const Text('توليد', style: TextStyle(color: Colors.white)),
            onPressed: () {
              Navigator.pop(context);
              if (controller.text.isNotEmpty) {
                _generateRoutine(controller.text);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBlurCircle(Color color) {
    return Container(
      width: 200, height: 200,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.3),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
        child: Container(color: Colors.transparent),
      ),
    );
  }
}