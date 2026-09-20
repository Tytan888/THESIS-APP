import 'package:flutter/material.dart';
import 'package:karaoke_app/import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _pinController = TextEditingController(); // NEW
  bool _isLoading = false;

  Future<void> _handleLogin(BuildContext context) async {
    String username = _usernameController.text.trim().toLowerCase();
    String pin = _pinController.text.trim();

    if (username.isEmpty || pin.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      // 1. Format the dummy email
      String dummyEmail = '${username.toLowerCase()}@example.com';

      // 2. Authenticate with Firebase
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: dummyEmail,
        password: pin,
      );

      // 3. Preserve your existing global variable and SharedPreferences flow
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', username);
      currentUsername = username;

      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const MainMenuScreen()),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        String message = "Login failed.";
        if (e.code == 'user-not-found' ||
            e.code == 'wrong-password' ||
            e.code == 'invalid-credential') {
          message = "Invalid username or PIN.";
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Login")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: "Enter Username..."),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Enter PIN..."),
            ),
            const SizedBox(height: 20),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: () => _handleLogin(context),
                    child: const Text("Login"),
                  ),
          ],
        ),
      ),
    );
  }
}
