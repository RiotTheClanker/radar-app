<!-- version: v0.1.4 -->
<!--
  The notes for the NEXT release. CI reads this file at tag time and refuses
  to publish if the version marker above does not match the tag, so update
  both in the pull request that ships the change rather than afterwards.
  GitHub's generated commit list is appended below whatever is written here.
-->

### 3D view

**Hydrometeor classification.** A new 3D field labels every voxel by what the
radar is most likely looking at — rain, heavy rain, big drops, hail mixed with
rain, graupel, wet and dry snow, ice crystals, ground clutter or biological
scatterers — using a fuzzy-logic classifier over reflectivity, differential
reflectivity and correlation coefficient. The melting level is found from the
volume's own bright band rather than assumed, so the ice/liquid boundary
follows the day's atmosphere. A legend sits beside the render, and the
threshold slider switches between all classes and weather only.

It runs without KDP or the texture fields the operational NEXRAD algorithm
uses, so heavy rain and hail lean harder on Z and ZDR than they should, and
clutter with a high correlation coefficient can still be called weather. Good
for reading storm structure; not a substitute for the operational product.

**Fixed: the 3D view invented readings at the edge of the data** (#9). The
volume is a texture of palette indices, and the sampler filtered them, so
where data met empty space the index slid through the middle of the table.
Half way from 0 m/s to empty was a fully opaque −32 m/s that nothing measured
— which is what drew the cone standing on the radar site in velocity, ZDR and
CC. Reflectivity was never affected, because its low values are already
transparent. Value and coverage are now filtered separately.
