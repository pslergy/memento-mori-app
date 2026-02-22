// Создание канала с указанием типа (новостной, развлекательный и т.д.).

import 'package:flutter/material.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/channel_types.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

class CreateChannelScreen extends StatefulWidget {
  const CreateChannelScreen({super.key});

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  static const int _maxChannelsPerAccount = 2;

  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  String _selectedTypeId = kChannelTypes.first.id;
  bool _isPrivate = false;
  bool _loading = false;
  bool _checkingLimit = true;
  int _myChannelsCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkChannelLimit();
  }

  Future<void> _checkChannelLimit() async {
    if (!locator.isRegistered<ApiService>()) {
      setState(() => _checkingLimit = false);
      return;
    }
    final api = locator<ApiService>();
    if (api.isGhostMode) {
      setState(() => _checkingLimit = false);
      return;
    }
    try {
      final list = await api.getMyChannels();
      if (!mounted) return;
      setState(() {
        _myChannelsCount = list.length;
        _checkingLimit = false;
      });
    } catch (_) {
      if (mounted) setState(() => _checkingLimit = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_myChannelsCount >= _maxChannelsPerAccount) {
      setState(() => _error = 'Limit: $_maxChannelsPerAccount channels per account');
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter channel name');
      return;
    }
    if (!locator.isRegistered<ApiService>()) {
      setState(() => _error = 'Channels need internet');
      return;
    }
    final api = locator<ApiService>();
    if (api.isGhostMode) {
      setState(() => _error = 'Channels need internet');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await api.createChannel(
        name: name,
        description: _descController.text.trim().isEmpty ? null : _descController.text.trim(),
        type: _selectedTypeId,
        isPrivate: _isPrivate,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Create channel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_checkingLimit)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: AppColors.stealthOrange)))
            else if (_myChannelsCount >= _maxChannelsPerAccount)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.stealthOrange.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                  child: Text('Limit: $_maxChannelsPerAccount channels per account. You have $_myChannelsCount.', style: const TextStyle(color: AppColors.stealthOrange, fontSize: 13)),
                ),
              )
            else ...[
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Channel name',
                labelStyle: TextStyle(color: AppColors.textDim),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.white10),
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.stealthOrange),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              style: const TextStyle(color: Colors.white),
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              decoration: InputDecoration(
                labelText: 'Description (optional)',
                labelStyle: TextStyle(color: AppColors.textDim),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.white10),
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: AppColors.stealthOrange),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
            ),
            const SizedBox(height: 20),
            Text('Type', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.white10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedTypeId,
                  isExpanded: true,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(color: Colors.white),
                  items: kChannelTypes.map((t) {
                    return DropdownMenuItem(value: t.id, child: Text(t.labelEn));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedTypeId = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              value: _isPrivate,
              onChanged: (v) => setState(() => _isPrivate = v),
              title: const Text('Closed channel (invite only)', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text('Only people with invite link can join', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
              activeColor: AppColors.stealthOrange,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: (_loading || _myChannelsCount >= _maxChannelsPerAccount) ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.stealthOrange,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _loading
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Create channel'),
            ),
            ], // else (form only when under limit)
          ],
        ),
      ),
    );
  }
}
