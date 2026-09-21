import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_toast.dart';
import '../core/theme.dart';
import '../services/auth_api_service.dart';
import '../services/token_storage_service.dart';

/// Profile insurance management. Policies are stored against the logged-in
/// driver's MongoDB document; no insurance data is kept in the documents flow.
class InsuranceScreen extends StatefulWidget {
  final VoidCallback? onBackTap;
  const InsuranceScreen({super.key, this.onBackTap});

  @override
  State<InsuranceScreen> createState() => _InsuranceScreenState();
}

class _InsuranceScreenState extends State<InsuranceScreen> {
  Map<String, dynamic> _driver = {};
  Map<String, dynamic> _vehicle = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = TokenStorageService.instance.driverProfile;
    _setPolicies(local);
    final result = await AuthApiService.instance.getAuthenticatedProfile();
    if (mounted && result.isSuccess) _setPolicies(result.driver);
  }

  void _setPolicies(Map<String, dynamic>? profile) {
    if (!mounted || profile == null) return;
    setState(() {
      _driver = _map(profile['driverInsuranceDetails']);
      _vehicle = _map(profile['vehicleInsuranceDetails']);
    });
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  String _value(Map<String, dynamic> policy, String key, String fallback) {
    final value = policy[key]?.toString().trim();
    return value == null || value.isEmpty || value == 'null' ? fallback : value;
  }

  String _date(Map<String, dynamic> policy, String key) {
    final raw = policy[key]?.toString();
    final value = raw == null ? null : DateTime.tryParse(raw);
    return value == null ? 'Not added' : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
  }

  String _status(Map<String, dynamic> policy) {
    final expiry = DateTime.tryParse(policy['expiryDate']?.toString() ?? '');
    if (expiry != null && expiry.isBefore(DateTime.now())) return 'Expired';
    return _value(policy, 'status', 'Pending');
  }

  Color _statusColor(String status) => status == 'Expired'
      ? QuickServeColors.statusRed
      : status == 'Pending'
          ? QuickServeColors.primaryOrange
          : QuickServeColors.statusGreen;

  Future<void> _edit({required bool driver}) async {
    final old = driver ? _driver : _vehicle;
    final company = TextEditingController(text: _value(old, 'insuranceCompany', ''));
    final number = TextEditingController(text: _value(old, 'policyNumber', ''));
    final yearly = TextEditingController(text: _value(old, 'yearlyPackage', 'Annual'));
    final premium = TextEditingController(text: _value(old, 'premiumAmount', ''));
    final coverage = TextEditingController(text: _value(old, 'coverageAmount', driver ? '₹5,00,000' : 'Based on vehicle repair/damage assessment'));
    DateTime? start = DateTime.tryParse(old['startDate']?.toString() ?? '');
    DateTime? expiry = DateTime.tryParse(old['expiryDate']?.toString() ?? '');
    String? fileName = old['documentName']?.toString();
    Uint8List? bytes;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialog) => AlertDialog(
          title: Text(driver ? 'Driver Insurance' : 'Vehicle Insurance'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: company, decoration: const InputDecoration(labelText: 'Insurance Company')),
              TextField(controller: number, decoration: const InputDecoration(labelText: 'Policy Number')),
              TextField(controller: coverage, decoration: const InputDecoration(labelText: 'Coverage / Fund')),
              TextField(controller: yearly, decoration: const InputDecoration(labelText: 'Annual / Yearly Package')),
              TextField(controller: premium, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Premium Amount')),
              _dateButton('Policy Start Date', start, (date) => setDialog(() => start = date)),
              _dateButton('Policy Expiry / Renewal Date', expiry, (date) => setDialog(() => expiry = date)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'], withData: true);
                  final file = picked?.files.single;
                  if (file == null || file.bytes == null || file.bytes!.lengthInBytes > 7 * 1024 * 1024) {
                    if (dialogContext.mounted) AppToast.error(dialogContext, 'Choose a PDF or image smaller than 7 MB.');
                    return;
                  }
                  setDialog(() { fileName = file.name; bytes = file.bytes; });
                },
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(fileName == null || fileName!.isEmpty ? 'Upload Policy Document' : fileName!),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if ([company.text, number.text, yearly.text, premium.text].any((text) => text.trim().isEmpty) || start == null || expiry == null || fileName == null || fileName!.isEmpty) {
                  AppToast.error(context, 'Complete all policy details and upload the document.');
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final policy = <String, dynamic>{
      'insuranceCompany': company.text.trim(), 'policyNumber': number.text.trim(),
      'coverageAmount': coverage.text.trim(), 'yearlyPackage': yearly.text.trim(),
      'premiumAmount': premium.text.trim(), 'startDate': start!.toIso8601String(),
      'expiryDate': expiry!.toIso8601String(), 'documentName': fileName,
      if (bytes != null) 'documentData': base64Encode(bytes!),
      'status': expiry!.isBefore(DateTime.now()) ? 'Expired' : 'Active',
    };
    setState(() => _saving = true);
    final result = await AuthApiService.instance.updateProfile(
      driverInsuranceDetails: driver ? policy : null,
      vehicleInsuranceDetails: driver ? null : policy,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.success) { AppToast.error(context, result.message); return; }
    _setPolicies(result.driver);
    AppToast.success(context, '${driver ? 'Driver' : 'Vehicle'} insurance saved successfully.');
  }

  Widget _dateButton(String label, DateTime? date, ValueChanged<DateTime> changed) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      icon: const Icon(Icons.calendar_today_outlined, size: 16),
      label: Text('$label: ${date == null ? 'Select' : '${date.day}/${date.month}/${date.year}'}'),
      onPressed: () async {
        final selected = await showDatePicker(context: context, initialDate: date ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
        if (selected != null) changed(selected);
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: QuickServeColors.surfaceLight,
    appBar: AppBar(backgroundColor: Colors.white, elevation: 0, leading: IconButton(icon: const Icon(Icons.arrow_back, color: QuickServeColors.textDark), onPressed: widget.onBackTap ?? () => Navigator.maybePop(context)), title: const Text('Insurance', style: TextStyle(color: QuickServeColors.textDark, fontWeight: FontWeight.bold))),
    body: Stack(children: [
      ListView(padding: const EdgeInsets.all(16), children: [
        _policyCard('DRIVER INSURANCE', 'Personal Accident Insurance', _driver, true),
        const SizedBox(height: 16),
        _policyCard('VEHICLE INSURANCE', 'Vehicle Insurance', _vehicle, false),
      ]),
      if (_saving) const Center(child: CircularProgressIndicator()),
    ]),
  );

  Widget _policyCard(String title, String policyTitle, Map<String, dynamic> policy, bool driver) {
    final status = _status(policy);
    return Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: QuickServeColors.borderLight)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: QuickServeColors.primaryBlue, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6), Text(policyTitle, style: const TextStyle(color: QuickServeColors.textDark, fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      _row('Coverage / Claim Amount', _value(policy, 'coverageAmount', driver ? '₹5,00,000' : 'Based on vehicle repair/damage assessment')),
      _row('Insurance Company', _value(policy, 'insuranceCompany', 'Not added')),
      _row('Policy Number', _value(policy, 'policyNumber', 'Not added')),
      _row('Yearly Package', _value(policy, 'yearlyPackage', 'Not added')),
      _row('Premium Amount', _value(policy, 'premiumAmount', 'Not added')),
      _row('Start Date', _date(policy, 'startDate')), _row('Expiry / Renewal Date', _date(policy, 'expiryDate')),
      const SizedBox(height: 8), Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: _statusColor(status).withOpacity(.12), borderRadius: BorderRadius.circular(12)), child: Text(status, style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.bold, fontSize: 12))), const Spacer(), TextButton.icon(onPressed: _saving ? null : () => _edit(driver: driver), icon: Icon(policy.isEmpty ? Icons.upload_file_outlined : Icons.edit_outlined, size: 17), label: Text(status == 'Expired' ? 'Renew' : policy.isEmpty ? 'Upload' : 'Edit'))]),
    ]));
  }

  Widget _row(String label, String value) => Padding(padding: const EdgeInsets.only(bottom: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 132, child: Text(label, style: const TextStyle(color: QuickServeColors.textSecondary, fontSize: 12))), Expanded(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(color: QuickServeColors.textDark, fontSize: 12, fontWeight: FontWeight.w600)))]));
}
