/// Barrel for the app's shared domain model.
///
/// The UI layer should import this rather than reaching into `main.dart`:
/// everything here is deliberately free of widgets and of app state, so a
/// replacement UI can be written against it without touching the controller
/// or the data layer.
library;

export 'basemap.dart';
export 'display_frame.dart';
export 'geo.dart';
export 'lightning_source.dart';
export 'product.dart';
