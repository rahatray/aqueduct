import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import '../http/request.dart';
import '../http/request_sink.dart';
import 'application.dart';
import 'application_configuration.dart';
import 'package:stack_trace/stack_trace.dart';

/// Manages listening for HTTP requests and delivering them to [RequestSink] instances.
///
/// An Aqueduct application creates instances of this type to pair an HTTP server and an
/// instance of an application-specific [RequestSink]. Instances are created by [Application]
/// and shouldn't be created otherwise.
class ApplicationServer {
  /// Creates an instance of this type.
  ///
  /// You should not need to invoke this method directly.
  ApplicationServer(this.configuration, this.identifier, {this.captureStack: false});

  /// The configuration this instance used to start its [sink].
  ApplicationConfiguration configuration;

  /// The underlying [HttpServer].
  HttpServer server;

  /// The instance of [RequestSink] serving requests.
  RequestSink sink;

  /// Used during debugging to capture the stacktrace better for asynchronous calls.
  ///
  /// Defaults to false.
  bool captureStack;

  /// Target for sending messages to other [RequestSink] isolates.
  ///
  /// Events are added to this sink by instances of [ApplicationMessageHub] and should not otherwise be used.
  EventSink<dynamic> hubSink;

  bool get requiresHTTPS => _requiresHTTPS;
  bool _requiresHTTPS = false;

  /// The unique identifier of this instance.
  ///
  /// Each instance has its own identifier, a numeric value starting at 1, to identify it
  /// among other instances.
  int identifier;

  /// The logger of this instance
  Logger get logger => new Logger("aqueduct");

  /// Starts this instance, allowing it to receive HTTP requests.
  ///
  /// Do not invoke this method directly, [Application] instances are responsible
  /// for calling this method.
  Future start(RequestSink sink, {bool shareHttpServer: false}) async {
    logger.fine("ApplicationServer($identifier).start entry");
    this.sink = sink;
    sink.server = this;

    sink.setupRouter(sink.router);
    sink.router?.finalize();
    sink.nextController = sink.initialController;

    logger.fine("ApplicationServer($identifier).start binding HTTP");
    var securityContext = sink.securityContext;
    if (securityContext != null) {
      _requiresHTTPS = true;

      server = await HttpServer.bindSecure(configuration.address,
          configuration.port, securityContext,
          requestClientCertificate: configuration.isUsingClientCertificate,
          v6Only: configuration.isIpv6Only,
          shared: shareHttpServer);
    } else {
      _requiresHTTPS = false;

      server = await HttpServer.bind(
          configuration.address, configuration.port,
          v6Only: configuration.isIpv6Only, shared: shareHttpServer);
    }

    logger.fine("ApplicationServer($identifier).start bound HTTP");
    return didOpen();
  }

  Future close() async {
    logger.fine("ApplicationServer($identifier).close Closing HTTP listener");
    await server?.close(force: true);
    logger.fine("ApplicationServer($identifier).close Closing request sink");
    await sink?.close();

    // This is actually closed by sink.messageHub.close, but this shuts up the analyzer.
    hubSink?.close();
    logger.fine("ApplicationServer($identifier).close Closing complete");
  }

  /// Invoked when this server becomes ready receive requests.
  ///
  /// This method will invoke [RequestSink.willOpen] and await for it to finish.
  /// Once [RequestSink.willOpen] completes, the underlying [server]'s HTTP requests
  /// will be sent to this instance's [sink].
  ///
  /// [RequestSink.didOpen] is invoked after this opening has completed.
  Future didOpen() async {
    server.serverHeader = "aqueduct/${this.identifier}";

    await sink.willOpen();

    logger.fine("ApplicationServer($identifier).didOpen start listening");
    if (captureStack) {
      server.map((baseReq) => new Request(baseReq)).listen((req) {
        Chain.capture(() {
          sink.receive(req);
        });
      });
    } else {
      server.map((baseReq) => new Request(baseReq)).listen(sink.receive);
    }

    sink.didOpen();
    logger.info("Server aqueduct/$identifier started.");
  }

  void sendApplicationEvent(dynamic event) {
    // By default, do nothing
  }
}