/// Where lightning strikes are streamed from.
library;

enum LightningSource {
  off,
  blitzortung,
  glm,
  both;

  bool get on => this != LightningSource.off;
  bool get usesBlitzortung =>
      this == LightningSource.blitzortung || this == LightningSource.both;
  bool get usesGlm =>
      this == LightningSource.glm || this == LightningSource.both;
}
