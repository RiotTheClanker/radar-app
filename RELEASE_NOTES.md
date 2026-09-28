<!-- version: v0.3.2 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### Future radar removed

The **Future radar** tool, the fast-forward button that extrapolated the
latest scans up to 60 minutes ahead, has been taken out. It ran, but where it
put the storms was not accurate enough to be worth showing. The radar now
always shows real scans. Storm tracks are unchanged: their forecast positions
are the NWS's own, not the app's.
