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

    test('an isolated pane does not drive the others', () {
      // The half that was missing. An isolated pane correctly ignored
      // everyone else's radar changes, but changing *its* radar still
      // dragged the rest along, which is a control that only works when you
      // push on it from one side.
      expect(
        WorkspaceState.reachesGroup(sourceIsolated: true, linked: true),
        isFalse,
      );
    });

    test('a pane in the group drives the others when linked', () {
      expect(
        WorkspaceState.reachesGroup(sourceIsolated: false, linked: true),
        isTrue,
      );
    });

    test('nothing propagates when the group is unlinked', () {
      for (final isolated in [true, false]) {
        expect(
          WorkspaceState.reachesGroup(sourceIsolated: isolated, linked: false),
          isFalse,
        );
      }
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
