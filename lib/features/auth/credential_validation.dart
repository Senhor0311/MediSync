String? validateEmail(String? value) =>
    value == null ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())
    ? 'Enter a valid email address.'
    : null;

String? validateNewPassword(String? value) =>
    value == null ||
        value.length < 12 ||
        !RegExp('[a-z]').hasMatch(value) ||
        !RegExp('[0-9]').hasMatch(value)
    ? 'Use at least 12 characters including a lowercase letter and a number.'
    : null;
