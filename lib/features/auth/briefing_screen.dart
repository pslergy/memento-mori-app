import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_gate_screen.dart';

class BriefingScreen extends StatelessWidget {
  const BriefingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 🔥 ИСПРАВЛЕНО: visibility_off с маленькой буквы
              const Icon(Icons.visibility_off, color: Colors.redAccent, size: 60),
              const SizedBox(height: 30),
              Text("PROTOCOL: INITIALIZATION",
                  style: GoogleFonts.russoOne(color: Colors.white, fontSize: 20, letterSpacing: 2)),
              const SizedBox(height: 25),
              const Text(
                "To protect your communication, this application is camouflaged as a standard Calculator.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, height: 1.5, fontSize: 15),
              ),
              const SizedBox(height: 35),

              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: const Color(0xFF0D0D0D),
                    border: Border.all(color: Colors.white10),
                    borderRadius: BorderRadius.circular(15)
                ),
                child: Column(
                  children: [
                    const Text("SECRET ACCESS CODE:", style: TextStyle(color: Colors.white38, fontSize: 11)),
                    const SizedBox(height: 10),
                    Text("3301", style: GoogleFonts.robotoMono(color: Colors.greenAccent, fontSize: 44, fontWeight: FontWeight.bold, letterSpacing: 8)),
                  ],
                ),
              ),

              const SizedBox(height: 30),
              const Text(
                "Type the code and press '=' in the calculator to unlock your secure terminal.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13, fontStyle: FontStyle.italic),
              ),
              const Spacer(),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 55),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                ),
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('isFirstRun', false);

                  if (context.mounted) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const AuthGateScreen()),
                    );
                  }
                },
                child: const Text("I HAVE MEMORIZED THE CODE", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}