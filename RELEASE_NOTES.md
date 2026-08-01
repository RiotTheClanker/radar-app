<!-- version: v0.1.4 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### Fixed

**Thin black spokes through Level 2 data** (#28). Each radial claimed a slice
of azimuth as wide as it reported itself to be, which tiles perfectly for
Level 3 — exactly one degree, on whole degrees — but not for Level 2.
Super-resolution start azimuths drift, so one radial would cover 10.0-10.5°
while the next started at 10.57°, and the sliver between belonged to nobody.
Every such sliver drew as a black line radiating from the radar. The 3D view
had the same holes, as empty columns through the volume.

Slivers now go to whichever neighbouring radial is nearer, but only across
gaps under two degrees, so a sector the radar genuinely did not scan stays
empty instead of being filled with invented coverage.

### Color key

Hydrometeor classification now gets a list of its classes down the side of
the map, where the color scale usually goes, since a scale labelled with
class ids is not something you can read a value off. The colors are the NWS's
own, which are not the ones our 3D classifier uses — a legend drawn with the
wrong palette would name every class incorrectly, so a test checks it against
the table the map is actually painted with.

The 3D view now has a key for **every** field, not just the classified one:
a colour scale in that field's own units for reflectivity, wind, ZDR and
correlation coefficient, and the class list for hydrometeor classification.
It sits down the right edge, the same place it does on the 2D map, and is
built from the same table the renderer painted with, so an imported `.pal`
changes it too.

One thing it does not show for the continuous fields: the opacity slider
makes weak values transparent in 3D, and the key still lists them. It says
what a colour means, not what is currently visible. The classified field is
the exception — see below.

### The key is the filter, for hydrometeor classification

The 3D filter used to be a switch on the classified field: everything, or
everything except clutter and biological. Now every class in the key is its
own switch — tap it to hide that class, tap it again to bring it back. Hide
everything but graupel and hail and you are looking at the updrafts.

Per class rather than a slider because the classes have no natural order to
slide along. Any threshold would have to invent one, and would then only
reach the combinations that ordering happened to allow; "graupel and hail,
but not the snow below them" is not a prefix of anything.

A hidden class stays in the key, greyed and struck through, rather than
disappearing. You can see what you cut, you can tell it apart from a class
the radar never saw, and the row is still there to switch back on. "Show all"
at the top of the key clears the lot.

The key still lists the classes heaviest first, which is the order a storm is
read in and not the order they are numbered in.

### Storm tracks

The NWS's own storm cells, from the Level 3 STI product: each cell's id and
position, how fast and which way it is moving, its forecast track out to an
hour, and the NWS's own estimate of how wrong that track is likely to be.

It is its own overlay, so it draws over velocity, ZDR or correlation
coefficient exactly as over reflectivity. Tap a cell for detail. A cell the
NWS has no movement solution for yet is drawn hollow and marked new rather
than given an invented arrow.

These are NOAA's numbers, not ours. Their SCIT runs across seven reflectivity
thresholds with full vertical integration, which no single-threshold reading
of one 2D field on device could match.

### Rotation and tornado signatures

Mesocyclone detections ride along with the storm tracks overlay, from the
NWS's own Mesocyclone Detection Algorithm: where the rotation is, how strong,
its peak rotational velocity, and which storm cell it belongs to. A
circulation the tornado vortex signature algorithm has fired on is marked
separately and in red.

A radar signature is not a confirmed tornado and is not a warning. Follow
official NWS warnings.

### 3D view

**Hydrometeor classification.** A new 3D field labels every voxel by what the
radar is most likely looking at — rain, heavy rain, big drops, hail mixed with
rain, graupel, wet and dry snow, ice crystals, ground clutter or biological
scatterers — using a fuzzy-logic classifier over reflectivity, differential
reflectivity and correlation coefficient. The melting level is found from the
volume's own bright band rather than assumed, so the ice/liquid boundary
follows the day's atmosphere. A legend sits beside the render, and the
threshold slider switches between all classes and weather only.

Scored against the NWS's own classification at the four tilts it publishes,
across ten radars from Florida to Washington: **78.9% mean agreement**,
ranging 66% to 95%. Six of those sites were never used while tuning and
average 83.6%.

It runs without KDP or the texture fields the operational algorithm uses, and
that shows: ground clutter it still gets wrong more often than right, and it
is weakest over widespread stratiform ice, where telling dry snow from ice
crystals needs more than the three moments available here. Good for reading
storm structure; not a substitute for the operational product.

**Much better classification, from checking it against the NWS.** Comparing
our answer to theirs at the four tilts they publish turned up three real
faults, none of which was visible by eye:

The melting level could land on the ground. It is found from the volume's own
correlation-coefficient dip, and overnight the boundary layer fills with
insects, whose correlation coefficient is worse than any melting snow. On a
3am volume that put the melting level at 200 m and called the whole volume
ice. The dip must now be above 1 km and be a genuine layer, cleaner above and
below.

Insects and ground clutter were tied to the freezing level, which has nothing
to do with either. They are now placed by height above ground.

Correlation coefficient carried the least weight of the three moments, when
it is the best single indicator of whether a return is weather at all.

Agreement went from 8% to 78.9% averaged over ten radars. Biological returns
alone went from 35% to about 80%.

**Fixed: the 3D view invented readings at the edge of the data** (#9). The
volume is a texture of palette indices, and the sampler filtered them, so
where data met empty space the index slid through the middle of the table.
Half way from 0 m/s to empty was a fully opaque −32 m/s that nothing measured
— which is what drew the cone standing on the radar site in velocity, ZDR and
CC. Reflectivity was never affected, because its low values are already
transparent. Value and coverage are now filtered separately.
