import 'package:flutter/material.dart';

/// Harry Potter character avatars from Apryll Clark's Behance icon set.
/// https://www.behance.net/gallery/71431093/Harry-Potter-Icon-Set
class LiteraryAvatarInfo {
  const LiteraryAvatarInfo(this.label, this.assetPath);

  final String label;
  final String assetPath;
}

const List<LiteraryAvatarInfo> kLiteraryAvatars = [
  LiteraryAvatarInfo('Harry Potter', 'assets/avatars/01_harry.png'),
  LiteraryAvatarInfo('Hermione Granger', 'assets/avatars/02_hermione.png'),
  LiteraryAvatarInfo('Ron Weasley', 'assets/avatars/03_ron.png'),
  LiteraryAvatarInfo('Ginny Weasley', 'assets/avatars/04_ginny.png'),
  LiteraryAvatarInfo('Draco Malfoy', 'assets/avatars/05_draco.png'),
  LiteraryAvatarInfo('Neville Longbottom', 'assets/avatars/06_neville.png'),
  LiteraryAvatarInfo('Rubeus Hagrid', 'assets/avatars/07_hagrid.png'),
  LiteraryAvatarInfo('Albus Dumbledore', 'assets/avatars/08_dumbledore.png'),
  LiteraryAvatarInfo('Minerva McGonagall', 'assets/avatars/09_mcgonagall.png'),
  LiteraryAvatarInfo('Bellatrix Lestrange', 'assets/avatars/10_bellatrix.png'),
  LiteraryAvatarInfo('Severus Snape', 'assets/avatars/11_snape.png'),
  LiteraryAvatarInfo('Lord Voldemort', 'assets/avatars/12_voldemort.png'),
];

int clampLiteraryAvatarIndex(int index) =>
    index % kLiteraryAvatars.length;

/// Circular profile avatar using bundled Harry Potter character art.
class LiteraryCharacterAvatar extends StatelessWidget {
  const LiteraryCharacterAvatar({
    super.key,
    required this.index,
    this.size = 56,
    this.selected = false,
  });

  final int index;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final i = clampLiteraryAvatarIndex(index);
    final info = kLiteraryAvatars[i];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: selected
            ? Border.all(color: const Color(0xFFE8B86D), width: 3)
            : Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: const Color(0xFFE8B86D).withValues(alpha: 0.35),
                  blurRadius: 10,
                ),
              ]
            : null,
      ),
      child: ClipOval(
        child: Image.asset(
          info.assetPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => ColoredBox(
            color: const Color(0xFF1A1A22),
            child: Icon(Icons.person, size: size * 0.5, color: Colors.white54),
          ),
        ),
      ),
    );
  }
}
