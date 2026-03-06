import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart'; // لتنسيق التاريخ
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'db_helper.dart';
import 'notification_service.dart';
import 'auth_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // 1. المتغيرات الأساسية
  final LocalDBHelper _dbHelper = LocalDBHelper();
  final NotificationService _notificationService = NotificationService();
  final SupabaseClient _supabase = Supabase.instance.client;
  
  // استبدل هذا المفتاح بمفتاحك الخاص من Google AI Studio

  final String _geminiApiKey = dotenv.env['GEMINI_API_KEY']!; 
  late final GenerativeModel _geminiModel;

  List<Map<String, dynamic>> _tasks = [];
  bool _isLoading = false; // لعرض مؤشر التحميل أثناء عمل الذكاء الاصطناعي

  @override
  void initState() {
    super.initState();
    // إعداد Gemini (نستخدم flash لسرعته وقلة تكلفته)
    _geminiModel = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: _geminiApiKey,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json', // إجبار الرد بصيغة JSON
      ),
    );

    _loadLocalData(); // عرض البيانات المحلية فوراً (Offline-First)
    _syncData();      // بدء المزامنة في الخلفية
  }

  // ----------------------------------------------------------------
  // 2. منطق Offline-First والمزامنة (القلب النابض للتطبيق)
  // ----------------------------------------------------------------

  // تحميل البيانات من SQLite فقط (سريع جداً)
  Future<void> _loadLocalData() async {
    final userId = _supabase.auth.currentUser!.id;
    final data = await _dbHelper.getTasks(userId);
    setState(() {
      _tasks = data;
    });
  }

  // المزامنة: رفع المحلي غير المتزامن وجلب الجديد من السيرفر
  Future<void> _syncData() async {
    final userId = _supabase.auth.currentUser!.id;

    // أ) رفع المهام المحذوفة (Delete Sync)
    // أ) رفع المهام المحذوفة (Delete Sync)
    final deletedIds = await _dbHelper.getDeletedTasksQueue();
    if (deletedIds.isNotEmpty) {
      // تحويل القائمة إلى صيغة نصية يفهمها بوستجريس: ("id1","id2")
      // مثال: ("uuid-1","uuid-2")
      final idsString = '(${deletedIds.map((e) => '"$e"').join(',')})';
      
      // استخدام filter بدلاً من in_
      await _supabase
          .from('tasks')
          .delete()
          .filter('id', 'in', idsString); // تمت إضافة الفاصلة المنقوطة هنا
      
      for (var id in deletedIds) {
        await _dbHelper.removeFromDeletedQueue(id);
      }
    }

    // ب) رفع المهام الجديدة/المعدلة (Upsert Sync)
    final unsyncedTasks = await _dbHelper.getUnsyncedTasks();
    for (var task in unsyncedTasks) {
      // إعداد البيانات للسيرفر (تحويل البوليان)
      final taskForServer = {
        ...task,
        'is_completed': task['is_completed'] == 1,
        // نزيل الحقول المحلية التي لا توجد في السيرفر
        'is_synced': null 
      };
      taskForServer.remove('is_synced'); // تنظيف

      await _supabase.from('tasks').upsert(taskForServer);
      await _dbHelper.markTaskAsSynced(task['id']);
    }

    // ج) جلب أحدث البيانات من السيرفر (Pull Sync)
    try {
      final remoteData = await _supabase
          .from('tasks')
          .select()
          .eq('user_id', userId); // RLS يضمن ذلك، لكن للتأكيد

      for (var remoteTask in remoteData) {
        // تحويل البيانات لتناسب SQLite
        final localTask = {
          'id': remoteTask['id'],
          'user_id': remoteTask['user_id'],
          'title': remoteTask['title'],
          'scheduled_time': remoteTask['scheduled_time'], // نص ISO
          'is_completed': remoteTask['is_completed'] == true ? 1 : 0,
          'is_synced': 1, // لأنها قادمة من السيرفر فهي متزامنة
        };
        await _dbHelper.upsertTask(localTask);
        
        // إعادة جدولة الإشعارات للمهام غير المكتملة (لضمان عملها على أجهزة جديدة)
        if (localTask['is_completed'] == 0) {
          _notificationService.scheduleTaskNotification(
            taskId: localTask['id'],
            title: localTask['title'],
            scheduledTime: DateTime.parse(localTask['scheduled_time']),
          );
        }
      }
      
      // تحديث الواجهة بعد المزامنة الكاملة
      _loadLocalData();
      
    } catch (e) {
      // في حالة عدم وجود إنترنت، لا نفعل شيئاً، التطبيق يعمل محلياً بامتياز
      debugPrint("Sync failed (Offline mode): $e");
    }
  }

  // ----------------------------------------------------------------
  // 3. عمليات CRUD (Create, Update, Delete)
  // ----------------------------------------------------------------

  Future<void> _addTask(String title, DateTime time) async {
    final newId = const Uuid().v4(); // توليد ID محلياً
    final userId = _supabase.auth.currentUser!.id;

    final newTask = {
      'id': newId,
      'user_id': userId,
      'title': title,
      'scheduled_time': time.toIso8601String(),
      'is_completed': 0, // false
      'is_synced': 0, // غير متزامن بعد
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

  Future<void> _toggleTaskCompletion(String id, bool? value) async {
    final index = _tasks.indexWhere((t) => t['id'] == id);
    if (index == -1) return;

    var updatedTask = Map<String, dynamic>.from(_tasks[index]);
    updatedTask['is_completed'] = (value == true) ? 1 : 0;
    updatedTask['is_synced'] = 0; // يحتاج مزامنة

    await _dbHelper.upsertTask(updatedTask);
    
    // إلغاء الإشعار إذا اكتملت
    if (value == true) {
      await _notificationService.cancelNotification(id);
    }

    _loadLocalData();
    _syncData();
  }

  Future<void> _deleteTask(String id) async {
    await _dbHelper.deleteTask(id); // يحفظ أيضاً في طابور الحذف
    await _notificationService.cancelNotification(id);
    _loadLocalData();
    _syncData();
  }

  // ----------------------------------------------------------------
  // 4. الذكاء الاصطناعي (Gemini Integration)
  // ----------------------------------------------------------------

  Future<void> _generateRoutine(String goal) async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      
      // Prompt Engineering: الهندسة العكسية للطلب
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
        // تنظيف النص (احتياطاً)
        String cleanedJson = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
        List<dynamic> tasksJson = jsonDecode(cleanedJson);

        for (var t in tasksJson) {
          await _addTask(
            t['title'], 
            DateTime.parse(t['scheduled_time'])
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

  // تسجيل الخروج
  Future<void> _signOut() async {
    await _dbHelper.clearAllData(); // تنظيف البيانات المحلية للحفاظ على الخصوصية
    await _notificationService.cancelAll();
    await _supabase.auth.signOut();
    // AuthGate في main.dart سيعيدنا تلقائياً لصفحة الدخول
  }

  // ----------------------------------------------------------------
  // 5. واجهة المستخدم (Glassmorphism UI)
  // ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true, // للسماح للخلفية بالظهور خلف الـ AppBar
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
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          )
        ],
      ),
      body: Stack(
        children: [
          // أ) الخلفية المتدرجة
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0F172A), Color(0xFF1E1B4B)],
              ),
            ),
          ),
          
          // ب) دوائر خلفية جمالية
          Positioned(
            top: 100, right: -50,
            child: _buildBlurCircle(Colors.purple),
          ),
          Positioned(
            bottom: 100, left: -50,
            child: _buildBlurCircle(Colors.blueAccent),
          ),

          // ج) قائمة المهام
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

  // بطاقة المهمة الزجاجية
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
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white54),
                onPressed: () => _deleteTask(task['id']),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // نافذة الحوار لإدخال الهدف للذكاء الاصطناعي
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