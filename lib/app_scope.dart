import 'package:flutter/material.dart';

import 'services/firestore_service.dart';
import 'services/gemini_service.dart';
import 'services/lead_repository.dart';
import 'services/listing_filter_service.dart';
import 'services/listing_pipeline.dart';

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.repository, required super.child});

  final LeadRepository repository;

  FirestoreService get firestore => repository.community;
  ListingPipeline get pipeline => repository.pipeline;
  GeminiService get gemini => pipeline.gemini;
  ListingFilterService get filter => pipeline.filter;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in the tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return repository != oldWidget.repository;
  }
}
