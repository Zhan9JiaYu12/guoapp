import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A local entry screen; commands are never passed to a system shell.
class TerminalGate extends StatefulWidget {
  const TerminalGate({super.key, required this.child});
  final Widget child;

  @override
  State<TerminalGate> createState() => _TerminalGateState();
}

class _TerminalGateState extends State<TerminalGate>
    with WidgetsBindingObserver {
  final _command = TextEditingController();
  final _focus = FocusNode();
  bool _unlocked = false;
  String _output = 'Terminal ready.\nEnter command to continue.';
  DateTime? _backgroundAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showKeyboard();
  }

  void _showKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_unlocked) _focus.requestFocus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _backgroundAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundAt;
      _backgroundAt = null;
      if (_unlocked && since != null &&
          DateTime.now().difference(since) >= const Duration(minutes: 3)) {
        _command.clear();
        setState(() {
          _unlocked = false;
          _output = 'Session expired.\nEnter command to continue.';
        });
      }
      if (!_unlocked) _showKeyboard();
    }
  }

  void _submit(String command) {
    _command.clear();
    if (command.trim() == '011212') {
      _focus.unfocus();
      setState(() => _unlocked = true);
    } else {
      setState(() => _output = 'command not found');
      _showKeyboard();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _command.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    return MaterialApp(
      title: '终端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF101412),
        fontFamily: 'monospace',
        colorSchemeSeed: const Color(0xFF80E6A4),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Terminal'),
          backgroundColor: const Color(0xFF101412),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LOCAL CONSOLE', style: TextStyle(
                  color: Color(0xFF80E6A4), fontSize: 13,
                )),
                const SizedBox(height: 24),
                Text(_output, style: const TextStyle(
                  color: Color(0xFFB8C9BD), height: 1.7,
                )),
                const SizedBox(height: 20),
                Row(children: [
                  const Text('> ', style: TextStyle(
                    color: Color(0xFF80E6A4), fontSize: 22,
                  )),
                  Expanded(child: TextField(
                    controller: _command,
                    focusNode: _focus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(color: Color(0xFF80E6A4), fontSize: 22),
                    decoration: const InputDecoration(border: InputBorder.none),
                    onSubmitted: _submit,
                  )),
                  TextButton(
                    onPressed: () => _submit(_command.text),
                    child: const Text('↵ 回车'),
                  ),
                ]),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}
