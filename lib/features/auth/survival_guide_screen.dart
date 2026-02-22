import 'package:flutter/material.dart';
import 'package:memento_mori_app/features/camouflage/calculator_gate.dart';

class SurvivalGuideScreen extends StatelessWidget {
  const SurvivalGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              const Text(
                "TACTICAL BRIEFING",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 10),
              const Text("Read carefully. This is your only copy of the protocol.",
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 40),

              _buildStep(
                icon: Icons.calculate,
                title: "THE MASK",
                desc: "From now on, the app icon leads to a Calculator. It is a fully functional camouflage.",
              ),
              _buildStep(
                icon: Icons.vpn_key,
                title: "ACCESS: 3301",
                desc: "Type 3301 and press '=' to unlock your secure terminal.",
              ),
              _buildStep(
                // 🔥 ИСПРАВЛЕНО: Заменил на существующую иконку
                icon: Icons.gpp_maybe,
                title: "PANIC: 9111",
                desc: "If compromised, type 9111 and '='. This instantly purges all local data and logs you out.",
              ),
              _buildStep(
                icon: Icons.vibration,
                title: "SHAKE TO WIPE",
                desc: "Vigorous shaking of the device will initiate an emergency shutdown.",
              ),

              const Spacer(),
              const Center(
                child: Text("NEVER DISCLOSE THESE CODES.",
                    style: TextStyle(color: Colors.white10, fontSize: 10, letterSpacing: 5)),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 55),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const CalculatorGate()),
                        (route) => false,
                  );
                },
                child: const Text("I HAVE MEMORIZED THE PROTOCOL",
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep({required IconData icon, required String title, required String desc}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 25),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white70, size: 24),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
                const SizedBox(height: 4),
                Text(desc, style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}