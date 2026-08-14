part of 'wire_generated.dart';

// questions domain models.

/// Wire model AskUserQuestionAnswer.
final class AskUserQuestionAnswer {
  const AskUserQuestionAnswer({required this.answers});
  final List<Map<String, dynamic>> answers;
  factory AskUserQuestionAnswer.fromJson(Map<String, dynamic> json) {
    return AskUserQuestionAnswer(
      answers: [for (final e in (json['answers'] as List)) (e as Map<String, dynamic>)],
    );
  }
  Map<String, dynamic> toJson() => {
      'answers': [for (final e in answers) e],
  };
}

/// Wire model QuestionResponsePayload.
final class QuestionResponsePayload {
  const QuestionResponsePayload({required this.sessionId, required this.answer});
  final ApprovalRequestId sessionId;
  final AskUserQuestionAnswer answer;
  factory QuestionResponsePayload.fromJson(Map<String, dynamic> json) {
    return QuestionResponsePayload(
      sessionId: (json['sessionId'] as String),
      answer: AskUserQuestionAnswer.fromJson(json['answer'] as Map<String, dynamic>),
    );
  }
  Map<String, dynamic> toJson() => {
      'sessionId': sessionId,
      'answer': answer.toJson(),
  };
}

