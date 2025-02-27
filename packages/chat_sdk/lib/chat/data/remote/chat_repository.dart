import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_sdk/chat/data/mapper/chat_mappers.dart';
import 'package:chat_sdk/chat/data/remote/dto/chat_message_dto.dart';
import 'package:chat_sdk/chat/data/remote/dto/chat_room_create_dto.dart';
import 'package:chat_sdk/chat/domain/data_interfaces/chat_repository_interface.dart';
import 'package:chat_sdk/chat/domain/entity/chat_message.dart';
import 'package:chat_sdk/chat/domain/entity/chat_room.dart';
import 'package:chat_sdk/services/remote/builder/restapi_request_builder.dart';
import 'package:chat_sdk/services/remote/builder/socket_request_builder.dart';
import 'package:chat_sdk/services/remote/parser/socket_response_parser.dart';
import 'package:chat_sdk/services/remote/transport/http_transport.dart';
import 'package:chat_sdk/services/remote/transport/socket_transport.dart';
import 'package:chat_sdk/types/failure.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:fpdart/fpdart.dart';

class ChatRepositoryImpl implements IChatRepository {
  final HttpTransportInterface _http;
  final SocketTransport _socket;
  final ChatMapper _mapper;

  final Dio _dio = Dio();

  final String _lambdaBaseUrl = dotenv.env['LAMBDA_BASE_URL'] ?? '';
  final String _cloudFrontBaseUrl = dotenv.env['CLOUDFRONT_BASE_URL'] ?? '';
  final String _backendBaseUrl = dotenv.env['BACKEND_BASE_URL'] ?? '';

  ChatRepositoryImpl({
    required HttpTransportInterface http,
    required ChatMapper mapper,
  })  : _http = http,
        _mapper = mapper,
        _socket = SocketTransport(url: dotenv.env['SOCKET_URL'] ?? '');

  /// STOMP 소켓 연결
  @override
  TaskEither<Failure, Unit> connect() => _socket.connect();

  /// STOMP 소켓 연결 해제
  @override
  TaskEither<Failure, Unit> disconnect() => _socket.disconnect();

  /// 채팅 메시지 전송
  @override
  TaskEither<Failure, Unit> sendChatMessage({
    required String appId,
    required String roomId,
    required String accessToken,
    required String usersId,
    required String content,
    required String cloudFrontImageURL,
  }) {
    // 소켓 발행할 메시지 빌드
    final message = SocketMessageBuilder()
        .appId(appId)
        .roomId(roomId)
        .usersId(usersId)
        .content(content)
        .cloudFrontImageURL(cloudFrontImageURL)
        .type("CHAT")
        .build();

    return _socket.sendMessage(
      destination: "/app/chat.queue.$roomId",
      message: message,
      headers: {"Authorization": accessToken},
    );
  }

  /// 채팅 메시지 구독
  @override
  TaskEither<Failure, Stream<ChatMessage>> subscribeToChatMessages({
    required String roomId,
  }) {
    return _socket
        .subscribe(destination: "/exchange/chat.exchange/room.$roomId")
        .flatMap(
          (frameStream) {
        final parser = SocketResponseParser<ChatMessageDto>(
          parse: (json) {
            debugPrint("📨 수신된 원본 메시지: $json");
            return ChatMessageDto.fromJson(json);
          },
        );

        // frameStream을 ChatMessage로 매핑
        final Stream<ChatMessage> parsedStream =
        frameStream.asyncMap((frame) async {
          if (frame.body == null) {
            debugPrint("❌ STOMP Frame body가 null");
            throw Failure(
              error: Exception("STOMP Frame body가 null"),
              message: "STOMP Frame이 올바르지 않음",
              stackTrace: StackTrace.current,
            );
          }
          final parsedResult = parser.parseFrame(frame);
          return parsedResult.fold(
                (failure) {
              debugPrint("❌ 메시지 구독 파싱 실패: ${failure.message}");
              throw failure;
            },
                (chatMessageDto) async {
              final mappedResult = _mapper.fromChatMessageDto(chatMessageDto);
              return mappedResult.fold(
                    (failure) {
                  debugPrint("❌ 메시지 매핑 실패: ${failure.message}");
                  throw failure;
                },
                    (chatMessage) => chatMessage,
              );
            },
          );
        });

        return TaskEither.right(parsedStream);
      },
    );
  }

  /// 채팅방 목록 조회 예시
  @override
  TaskEither<Failure, List<ChatRoom>> requestChatRoomsList(int page, int size) {
    final requestBuilder = RestAPIRequestBuilder(baseUrl: _backendBaseUrl)
        .setEndpoint('chatrooms')
        .addQueryParameter('page', page)
        .addQueryParameter('size', size);

    return _http
        .get(requestBuilder.getUrl(), requestBuilder.buildHeaders())
        .flatMap((response) {
      // Json -> DTO -> Entity 변환
      return TaskEither.fromEither(
          _mapper.fromJsonToChatRoomListDto(response.data))
          .flatMap((dto) {
        return TaskEither.fromEither(_mapper.fromChatRoomListDto(dto));
      });
    });
  }

  /// 채팅방 생성 예시
  @override
  TaskEither<Failure, ChatRoom> createChatRoom({
    required String appId,
    required String accessToken,
    required String userId,
    required String roomName,
  }) {
    final createDto = ChatRoomCreateDto(
      userId: userId,
      name: roomName,
      type: ChatRoomType.group,
    );

    final requestBuilder = RestAPIRequestBuilder(baseUrl: _backendBaseUrl)
        .setEndpoint('chatrooms')
        .addHeader('Authorization', accessToken)
        .addHeader('App-Id', appId);

    final requestBody = jsonEncode(createDto.toJson());

    return _http
        .post(
      requestBuilder.getUrl(),
      requestBuilder.buildHeaders(),
      body: requestBody,
    )
        .flatMap(
          (_) => TaskEither.fromEither(_mapper.fromChatRoomCreateDto(createDto)),
    );
  }

  @override
  TaskEither<Failure, ChatRoom> enterChatRoom({
    required String appId,
    required String accessToken,
    required int roomId,
    required String userId,
  }) {
    return TaskEither.left(
      Failure(error: UnimplementedError(), message: "enterChatRoom 미구현"),
    );
  }

  @override
  TaskEither<Failure, ChatRoom> leaveChatRoom({
    required String appId,
    required String accessToken,
    required int roomId,
    required String userId,
  }) {
    return TaskEither.left(
      Failure(error: UnimplementedError(), message: "leaveChatRoom 미구현"),
    );
  }

  @override
  TaskEither<Failure, List<ChatRoom>> getUserChatRooms({
    required String userId,
  }) {
    return TaskEither.left(
      Failure(error: UnimplementedError(), message: "getUserChatRooms 미구현"),
    );
  }

  /// 람다(또는 API Gateway)를 통해 Presigned S3 URL 발급
  @override
  TaskEither<Failure, String> requestPresignedS3Url({
    required String fileName,
    required String fileType,
  }) {
    // 환경변수에서 Lambda Base Url 사용
    final endpoint = _lambdaBaseUrl;

    return TaskEither.tryCatch(
          () async {
        final response = await _dio.post(
          endpoint,
          data: {
            "body": {
              "fileName": fileName,
              "fileType": fileType,
            }
          },
        );

        final decoded =
        response.data is String ? jsonDecode(response.data) : response.data;

        if (decoded is! Map || !decoded.containsKey('body')) {
          throw Exception("Invalid Lambda response format");
        }
        final innerBody = jsonDecode(decoded['body']);
        if (!innerBody.containsKey('uploadURL')) {
          throw Exception("Missing uploadURL in response");
        }

        final uploadURL = innerBody['uploadURL'] as String;
        debugPrint("🟢 Presigned URL: $uploadURL");
        return uploadURL;
      },
          (error, stack) {
        debugPrint("❌ Presigned S3 URL 요청 실패: $error");
        return Failure(error: error, stackTrace: stack);
      },
    );
  }

  @override
  TaskEither<Failure, String> uploadFileToS3({
    required String accessToken,
    required File file,
  }) {
    // 이미 http(s)로 시작한다면, 재업로드 불필요
    if (file.path.startsWith("https://")) {
      debugPrint("이미 업로드된 URL, 그대로 반환: ${file.path}");
      return TaskEither.right(file.path);
    }

    final fileName = file.path.split('/').last;
    final fileType = "image/jpeg"; // 필요시 확장자에 따라 동적 처리

    // 1) Presigned S3 URL 발급
    return requestPresignedS3Url(
      fileName: fileName,
      fileType: fileType,
    ).flatMap((preSignedUrl) {
      debugPrint("🟢 PreSigned URL: $preSignedUrl");

      // 2) 실제 업로드
      return TaskEither<Failure, String>.tryCatch(
            () async {
          final fileBytes = await file.readAsBytes();
          debugPrint("🟢 파일 크기: ${fileBytes.length} bytes");

          final response = await _dio.put(
            preSignedUrl,
            data: fileBytes,
            options: Options(
              headers: {'Content-Type': fileType},
            ),
          );

          if (response.statusCode != null &&
              response.statusCode! >= 200 &&
              response.statusCode! < 300) {
            // 업로드 성공 → CloudFront 주소로 치환
            final cloudFrontUrl = "$_cloudFrontBaseUrl/uploads/$fileName";
            debugPrint("✅ 업로드 완료: $cloudFrontUrl");
            return cloudFrontUrl;
          } else {
            throw Exception(
              "S3 업로드 실패: ${response.statusCode} - ${response.data}",
            );
          }
        },
            (error, stack) {
          debugPrint("❌ S3 업로드 예외 발생: $error");
          return Failure(error: error, stackTrace: stack);
        },
      );
    });
  }

  /// 채팅방 히스토리 불러오기 예시
  @override
  TaskEither<Failure, List<ChatMessage>> getChatHistory({
    required String roomId,
  }) {
    final requestBuilder = RestAPIRequestBuilder(
      baseUrl: _backendBaseUrl,
    )
        .setEndpoint('chatrooms/detail/$roomId')
        .addQueryParameter('page', 0)
        .addQueryParameter('size', 100);

    return _http
        .get(requestBuilder.getUrl(), requestBuilder.buildHeaders())
        .flatMap((response) {
      return TaskEither.fromEither(
        _mapper.fromJsonToChatMessageListDto(response.data),
      ).map((chatMessages) {
        // DTO -> Entity 변환 예시
        return chatMessages.map((msg) => msg).toList();
      });
    });
  }
}
