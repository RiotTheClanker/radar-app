import 'package:flutter_test/flutter_test.dart';
import 'package:radar_app/ui/workspace_state.dart';

/// [WorkspaceState] starts an alert poll and the animation clock in its
/// constructor, so every test has to dispose it before the binding checks
/// for pending timers.
void _withState(void Function(WorkspaceState s) body) {
  final s = WorkspaceState();
  try {
    body(s);
  } finally {
    s.dispose();
  }
}

void main() {
  group('site linkage follows view linkage', () {
    test('linked panes share a radar', () {
      _withState((s) {
        expect(s.linkViews, isTrue);
        expect(s.linkSite, isTrue);
        expect(s.propagatesSite, isTrue);
      });
    });

    test('unlinking the views unlinks the radar with them', () {
      _withState((s) {
        s.setLinkViews(false);
        // Panes panning separately are not looking at the same weather, so
        // dragging them onto a different radar is as likely to throw away
        // the view someone set up as to help.
        expect(s.propagatesSite, isFalse);
      });
    });

    test('the site link stays off once views come back', () {
      _withState((s) {
        s.setLinkSite(false);
        s.setLinkViews(false);
        expect(s.propagatesSite, isFalse);

        s.setLinkViews(true);
        // Views being linked again does not silently re-enable a site link
        // the user turned off.
        expect(s.propagatesSite, isFalse);

        s.setLinkSite(true);
        expect(s.propagatesSite, isTrue);
      });
    });

    test('linked views with independent radars is still reachable', () {
      _withState((s) {
        s.setLinkSite(false);
        // Two radars on one storm, for comparing coverage: the panes stay
        // pointed at the same ground but keep their own sites.
        expect(s.linkViews, isTrue);
        expect(s.propagatesSite, isFalse);
      });
    });
  });
}
