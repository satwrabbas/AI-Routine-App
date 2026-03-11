import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'db_helper.dart';
import 'notification_service.dart';

class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({super.key});

  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  final LocalDBHelper _dbHelper = LocalDBHelper();
  final NotificationService _notificationService = NotificationService();
  final String userId = Supabase.instance.client.auth.currentUser!.id;

  List<Map<String, dynamic>> _routines =[];
  Map<String, List<Map<String, dynamic>>> _routineTasks = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    // 1. جلب الروتينات
    final routines = await _dbHelper.getRoutines(userId);
    
    // 2. جلب المهام لكل روتين
    Map<String, List<Map<String, dynamic>>> tasksMap = {};
    for (var routine in routines) {
      final tasks = await _dbHelper.getTasksByRoutine(routine['id']);
      tasksMap[routine['id']] = tasks;
    }

    setState(() {
      _routines = routines;
      _routineTasks = tasksMap;
      _isLoading = false;
    });
  }

  // دالة استنساخ الروتين (The Killer Feature)
  Future<void> _reuseRoutine(String routineId) async {
    final tasks = _routineTasks[routineId] ??[];
    if (tasks.isEmpty) return;

    // سنبدأ جدولة المهام المستنسخة بعد 5 دقائق من الآن
    DateTime currentTime = DateTime.now().add(const Duration(minutes: 5));

    for (var oldTask in tasks) {
      final newId = const Uuid().v4();
      final newTask = {
        'id': newId,
        'user_id': userId,
        'routine_id': routineId, // ربطها بنفس الروتين
        'title': oldTask['title'],
        'scheduled_time': currentTime.toIso8601String(),
        'is_completed': 0,
        'is_synced': 0, // لنجبر المزامنة
      };

      // حفظ محلي
      await _dbHelper.upsertTask(newTask);
      
      // جدولة إشعار
      await _notificationService.scheduleTaskNotification(
        taskId: newId,
        title: oldTask['title'],
        scheduledTime: currentTime,
      );

      // زيادة الوقت للمهمة التالية (مثلاً نعطي 45 دقيقة لكل مهمة)
      currentTime = currentTime.add(const Duration(minutes: 45));
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تطبيق الروتين لليوم بنجاح! 🚀')),
      );
      // نعود للصفحة الرئيسية ونرسل true لكي نأمرها بتحديث الشاشة
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('مكتبة الروتينات', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withOpacity(0.2)),
          ),
        ),
      ),
      body: Stack(
        children:[
          // الخلفية
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors:[Color(0xFF0F172A), Color(0xFF1E1B4B)],
              ),
            ),
          ),
          
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _routines.isEmpty
                  ? Center(
                      child: Text(
                        'لم تقم بتوليد أي روتين بعد.\nاستخدم الذكاء الاصطناعي لإنشاء روتينك الأول!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withOpacity(0.6)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 100, left: 16, right: 16, bottom: 20),
                      itemCount: _routines.length,
                      itemBuilder: (context, index) {
                        final routine = _routines[index];
                        final tasks = _routineTasks[routine['id']] ??[];

                        return Card(
                          color: Colors.white.withOpacity(0.08),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          margin: const EdgeInsets.only(bottom: 16),
                          child: Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              iconColor: Colors.white,
                              collapsedIconColor: Colors.white70,
                              title: Text(
                                routine['title'],
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                'الطلب: ${routine['ai_prompt'] ?? 'بدون طلب'}',
                                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                              ),
                              children:[
                                // عرض المهام
                                ...tasks.map((t) => ListTile(
                                  leading: const Icon(Icons.check_circle_outline, color: Colors.white54, size: 20),
                                  title: Text(t['title'], style: const TextStyle(color: Colors.white70, fontSize: 14)),
                                )),
                                
                                // زر التطبيق
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFEC4899),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                      icon: const Icon(Icons.copy, color: Colors.white),
                                      label: const Text('تطبيق هذا الروتين اليوم', style: TextStyle(color: Colors.white)),
                                      onPressed: () => _reuseRoutine(routine['id']),
                                    ),
                                  ),
                                )
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ],
      ),
    );
  }
}