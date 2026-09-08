//
//  VoiceNativeLLMPolisher.swift
//  Squirrel (SquirrelVoice fork)
//
//  云端 LLM 语义清洗（OpenAI 兼容 /chat/completions）。
//
//  行为约定沿用第一代 Python 后端（cleaner.py，已废弃）：
//  - 松手后整段处理完再清洗，不参与实时预览；
//  - 用最近 N 条已提交文本做上下文（理解语境，删旁人插话/修同音字/去口水词）；
//  - 任何失败（网络/超时/鉴权/结构异常）→ 抛错，调用方回退 ASR 原文（绝不丢字）；
//  - LLM 判定「无有效语义」(NONE) → 返回空串，调用方同样回退原文。
//

import Foundation

final class VoiceNativeLLMPolisher {
  struct PolishError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let baseURL: String
  private let model: String
  private let apiKey: String
  private let timeoutS: Double
  private let session: URLSession
  /// 实际使用的系统提示词（配置覆盖为空时用 defaultSystemPrompt）。
  private let systemPrompt: String
  /// 上下文窗口：最近 N 条【已成功提交】文本（仅提交成功的才写入，防脏文本污染）。
  private var context: [String] = []
  private let maxContextTurns = 3

  init(baseURL: String, model: String, apiKey: String, timeoutS: Double = 10.0, systemPrompt: String? = nil) {
    self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    self.model = model
    self.apiKey = apiKey
    self.timeoutS = timeoutS
    let custom = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.systemPrompt = custom.isEmpty ? Self.defaultSystemPrompt : custom
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeoutS
    cfg.timeoutIntervalForResource = timeoutS + 5
    self.session = URLSession(configuration: cfg)
  }

  /// 记录一条成功提交的文本进上下文窗口。
  func addCommitted(_ text: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    context.append(t)
    if context.count > maxContextTurns { context.removeFirst(context.count - maxContextTurns) }
  }

  /// 清洗 ASR 原始文本。返回清洗后纯文本；空串 = 判定无有效内容（调用方回退原文）。
  func clean(_ rawText: String) async throws -> String {
    let messages = Self.buildMessages(rawText: rawText, context: context, systemPrompt: systemPrompt)
    var body: [String: Any] = [
      "model": model,
      "messages": messages,
      "temperature": 0.0,
      "stream": false,
      // Qwen3 思考模式关闭（DashScope 参数，其他 OpenAI 兼容服务忽略未知字段）
      "enable_thinking": false,
    ]
    var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = timeoutS
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      let detail = String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
      throw PolishError(message: "HTTP \(http.statusCode): \(detail)")
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = obj["choices"] as? [[String: Any]],
          let first = choices.first,
          let msg = first["message"] as? [String: Any],
          let content = msg["content"] as? String else {
      throw PolishError(message: "响应结构异常：\(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")")
    }
    return Self.postprocess(content)
  }

  /// 「测试连通性」：发一次最小请求验证端点/key/模型。返回 (成功, 错误, 延迟ms)。
  func testConnectivity() async -> (Bool, String?, Int?) {
    let start = Date()
    do {
      var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
      request.httpMethod = "POST"
      request.timeoutInterval = timeoutS
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      let body: [String: Any] = [
        "model": model,
        "messages": [["role": "user", "content": "hi"]],
        "max_tokens": 1,
        "stream": false,
      ]
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let latency = Int(Date().timeIntervalSince(start) * 1000)
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        return (true, nil, latency)
      } else if let http = response as? HTTPURLResponse {
        let detail = String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
        return (false, "HTTP \(http.statusCode): \(detail)", latency)
      }
      return (false, "无响应", latency)
    } catch {
      let latency = Int(Date().timeIntervalSince(start) * 1000)
      return (false, error.localizedDescription, latency)
    }
  }

  // MARK: - Prompt / 后处理（继承第一代 Python 后端；可在设置界面用自定义提示词覆盖）

  static let defaultSystemPrompt = """
  角色设定：
  你是语音转写文本清理器。输入是 ASR 原始转写文本，以及最近已成功提交的历史上下文（仅供理解当前话语的语境参考）。

  核心规则：
  1. 删除噪音：删除明显与用户当前输入无关的旁人插话/背景对话；去掉口水词（嗯、啊、那个、就是说等）。
  2. 补全标点：按语义加上合适的中文标点（逗号、句号、问号、感叹号等），原文已有的标点保留。
  3. 【重要】保留重复：用户重复说的字词/短语必须原样保留，次数与原文一致。例如"你好你好"不能合并为一个"你好"。重复是有意强调，视为有效内容。
  4. 技术术语修正（重点）：将常见的 ASR 中文音译还原为标准英文术语，确保大模型能正确理解：
     拍森 → Python
     杰森 / 贼森 → JSON
     诶屁爱 → API
     吉特 → Git
     安桌 → Android
     挨炮 → iPhone
     加哇 → Java
     瑞艾克特 → React
     维优 → Vue
     多可 → Docker
     扛破神 / k8s → Kubernetes（或保留 K8s）
     麦斯库 → MySQL
     芒果 → MongoDB
     艾欧 → IO
     艾 → AI
     雷克贝斯 → liquibase
     埃塞欧 → SSH（如有需要可追加）
     （你可以继续追加常用词）
  5. 中英混排规范：中文与英文单词、数字之间加一个半角空格，让排版更清晰。例如：
     调用Python脚本 → 调用 Python 脚本
     快3倍 → 快 3 倍
  6. 英文大小写：修正常见技术缩写的大小写：api → API，json → JSON，python → Python，git → Git。
  7. 拿不准时一律保留原文。

  输出要求：
  - 只输出清洗后的纯文本，不要任何解释、前缀或引号包裹。
  - NONE 判定：仅当整段输入为空或纯乱码（无任何可辨识语义）时才输出 NONE。重复字词是有意义内容，不能判为 NONE。
  """

  private static func buildMessages(rawText: String, context: [String], systemPrompt: String) -> [[String: String]] {
    var user = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !context.isEmpty {
      let ctxLines = context.map { "- \($0)" }.joined(separator: "\n")
      user = "最近已提交上下文（仅供理解当前话语语境）：\n\(ctxLines)\n\nASR 原始转写：\n\(user)"
    }
    return [
      ["role": "system", "content": systemPrompt],
      ["role": "user", "content": user],
    ]
  }

  /// 剥离 thinking 泄漏 / 引号包裹；NONE 哨兵 → 空串。
  private static func postprocess(_ content: String?) -> String {
    guard var text = content else { return "" }
    // 完整 thinking 块 + 孤立开/闭标签
    text = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "")
    text = text.replacingOccurrences(of: "</?think>", with: "")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // 引号包裹剥离
    let pairs: [(String, String)] = [("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("\"", "\""), ("'", "'")]
    if text.count >= 2 {
      let f = String(text.first!), l = String(text.last!)
      if pairs.contains(where: { $0.0 == f && $0.1 == l }) {
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    // NONE 哨兵 → 空串（无有效内容）
    if text.range(of: #"^\s*none\s*[。.!！]?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return ""
    }
    return text
  }
}
