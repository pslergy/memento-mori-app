import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// Встроенные тексты из `docs/*.md` (см. pubspec assets).
class E2eeDocsScreen extends StatefulWidget {
  const E2eeDocsScreen({super.key});

  @override
  State<E2eeDocsScreen> createState() => _E2eeDocsScreenState();
}

class _E2eeDocsScreenState extends State<E2eeDocsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  String? _priorities;
  String? _faq;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    try {
      final p = await rootBundle.loadString('docs/E2EE_PRIORITIES.md');
      final f = await rootBundle.loadString('docs/E2EE_USER_FAQ_RU.md');
      if (!mounted) return;
      setState(() {
        _priorities = p;
        _faq = f;
        _loadError = null;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        debugPrintStack(stackTrace: st, label: 'E2eeDocsScreen');
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'E2EE — приоритеты и FAQ',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.gridCyan,
          labelColor: AppColors.gridCyan,
          unselectedLabelColor: AppColors.textDim,
          tabs: const [
            Tab(text: 'Приоритеты'),
            Tab(text: 'FAQ (RU)'),
          ],
        ),
      ),
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Не удалось загрузить тексты.\n'
                  'Проверьте, что в pubspec.yaml указаны assets:\n'
                  'docs/E2EE_PRIORITIES.md, docs/E2EE_USER_FAQ_RU.md\n\n'
                  '$_loadError',
                  style: const TextStyle(color: AppColors.warningRed, fontSize: 12),
                ),
              ),
            )
          : _priorities == null
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.gridCyan),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _MarkdownPlainView(text: _priorities!),
                    _MarkdownPlainView(text: _faq ?? ''),
                  ],
                ),
    );
  }
}

class _MarkdownPlainView extends StatelessWidget {
  const _MarkdownPlainView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            height: 1.45,
            fontFamily: 'RobotoMono',
          ),
        ),
      ),
    );
  }
}
