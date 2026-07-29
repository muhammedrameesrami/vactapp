import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_tab.dart';
import 'history_screen.dart';
import 'profile_screen.dart';

/// Root shell that hosts the bottom navigation and swaps between tabs.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    HomeTab(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  void _onTabTapped(int index) {
    if (_currentIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B13),
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: _GlassNavBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
      ),
    );
  }
}

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({required this.currentIndex, required this.onTap});
  final int currentIndex;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final items = [
      _NavItem(icon: Icons.people_alt_rounded, label: 'Home'),
      _NavItem(icon: Icons.history_rounded, label: 'History'),
      _NavItem(icon: Icons.person_rounded, label: 'Profile'),
    ];

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (i) {
                  final selected = currentIndex == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => onTap(i),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                              decoration: BoxDecoration(
                                gradient: selected
                                    ? const LinearGradient(
                                        colors: [Color(0xFF8A2BE2), Color(0xFF00E5FF)],
                                      )
                                    : null,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: const Color(0xFF8A2BE2).withValues(alpha: 0.4),
                                          blurRadius: 12,
                                        )
                                      ]
                                    : null,
                              ),
                              child: Icon(
                                items[i].icon,
                                color: selected ? Colors.white : Colors.white38,
                                size: 22,
                              ),
                            ),
                            const SizedBox(height: 4),
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 250),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                                color: selected ? const Color(0xFF00E5FF) : Colors.white38,
                              ),
                              child: Text(items[i].label),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}
