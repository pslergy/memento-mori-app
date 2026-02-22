import 'package:flutter/material.dart';

/// 🔍 Validation Helper
/// Centralized validation logic for registration forms

class ValidationHelper {
  static String? validateUsername(String? value) {
    if (value == null || value.isEmpty) {
      return "Username is required";
    }
    if (value.length < 3) {
      return "Username must be at least 3 characters";
    }
    if (value.length > 20) {
      return "Username must be no more than 20 characters";
    }
    // Only Latin letters, numbers, and underscores
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
      return "Username can only contain letters, numbers, and underscores";
    }
    return null;
  }

  static String? validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return "Email is required";
    }
    // Basic email format validation
    final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
    if (!emailRegex.hasMatch(value)) {
      return "Please enter a valid email address";
    }
    return null;
  }

  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return "Password is required";
    }
    if (value.length < 8) {
      return "Password must be at least 8 characters";
    }
    // Must contain at least one letter and one number
    if (!RegExp(r'[a-zA-Z]').hasMatch(value)) {
      return "Password must contain at least one letter";
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return "Password must contain at least one number";
    }
    return null;
  }

  static String getPasswordStrength(String password) {
    if (password.length < 8) return "Weak";
    bool hasLetter = RegExp(r'[a-zA-Z]').hasMatch(password);
    bool hasNumber = RegExp(r'[0-9]').hasMatch(password);
    bool hasSpecial = RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password);
    
    int strength = 0;
    if (hasLetter) strength++;
    if (hasNumber) strength++;
    if (hasSpecial) strength++;
    if (password.length >= 12) strength++;
    
    if (strength <= 1) return "Weak";
    if (strength == 2) return "Medium";
    if (strength == 3) return "Strong";
    return "Very Strong";
  }

  static Color getPasswordStrengthColor(String password) {
    final strength = getPasswordStrength(password);
    switch (strength) {
      case "Weak":
        return Colors.redAccent;
      case "Medium":
        return Colors.orangeAccent;
      case "Strong":
        return Colors.yellowAccent;
      case "Very Strong":
        return Colors.greenAccent;
      default:
        return Colors.white54;
    }
  }
}
