import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client weatherClient() => IOClient(
  HttpClient()..findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri),
);
