# One chat completion against whichever provider a role resolves to.
#
# Gemini and DeepSeek both speak the OpenAI chat format, so this is the only client the
# pipeline needs; Llm::Provider decides where the request goes and as which model.
#
# Two things here exist because of behaviour measured against the live APIs rather than
# read from their docs. See THINKING and the empty-content check in `extract`.
module Llm
  class Completion < ApplicationService
    NETWORK_ERRORS = Gpc::HttpFetcher::NETWORK_ERRORS

    TIMEOUT_SECONDS = 300
    DEFAULT_MAX_TOKENS = 8_000

    # `deepseek-flash` reasons before answering and bills that reasoning as output. At
    # its default effort it spends roughly 4.6 tokens thinking per token of answer, and
    # under a budget sized for the answer alone it consumes the whole allowance thinking
    # and returns an empty string with finish_reason "length" and no error — a failure
    # that looks exactly like success. Disabling it costs nothing in output quality for
    # generation and cuts output tokens by 4.4x.
    #
    # Only sent to providers that know the field. Gemini's compatibility layer answers
    # 400 "Unknown name: thinking" rather than ignoring it, so the switch is a per-
    # provider capability rather than something this client can send unconditionally.
    THINKING = { type: "disabled" }.freeze

    # The JSON object a reply holds, or nil — also for JSON that is not an object, which
    # no caller asks for. Asked for JSON alone, models still sometimes fence it in markdown.
    def self.json_in(content)
      parsed = JSON.parse(content.to_s.strip.sub(/\A```(?:json)?/, "").sub(/```\z/, "").strip)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def initialize(role:, prompt:, max_tokens: DEFAULT_MAX_TOKENS, thinking: false)
      super()
      @provider = Llm::Provider.for(role)
      @prompt = prompt
      @max_tokens = max_tokens
      @thinking = thinking
    end

    def call
      return failure("Falta la clave de #{provider.role}") unless provider.configured?

      response = post
      return failure if has_errors?

      extract(response)
    end

    def context_for_logging
      { provider: provider.to_s, role: provider.role }
    end

    private

    attr_reader :provider, :prompt, :max_tokens, :thinking

    def post
      response = HTTParty.post(endpoint, headers: headers, body: body, timeout: TIMEOUT_SECONDS)
      unless response.success?
        failure("#{provider} respondió #{response.code}: #{response.body.to_s.squish.truncate(200)}")
        return nil
      end

      # Parsed here rather than through HTTParty, which decides by Content-Type: a
      # provider that labels its JSON text/plain would otherwise hand back a String and
      # fail several lines later as a NoMethodError.
      JSON.parse(response.body)
    rescue JSON::ParserError
      failure("#{provider} devolvió una respuesta ilegible")
      nil
    rescue *NETWORK_ERRORS => e
      failure("No se pudo llamar a #{provider}: #{e.class} #{e.message}")
      nil
    end

    def endpoint
      "#{provider.base_url.chomp("/")}/chat/completions"
    end

    def headers
      { "Authorization" => "Bearer #{provider.api_key}", "Content-Type" => "application/json" }
    end

    def body
      # Every caller asks for one JSON object. Left to the prompt alone, gemini-3.8-flash
      # broke it in 9 of 50 generation calls (2026-09-26) — each one paid for and thrown
      # away; JSON mode is honoured by both Gemini and DeepSeek, verified against each.
      payload = { model: provider.model, messages: [{ role: "user", content: prompt }],
                  max_tokens: max_tokens, response_format: { type: "json_object" } }
      payload[:thinking] = THINKING if provider.supports_thinking? && !thinking
      payload[:reasoning_effort] = provider.reasoning_effort if provider.reasoning_effort
      payload.to_json
    end

    def extract(response)
      choice = response.dig("choices", 0) || {}
      content = choice.dig("message", "content").to_s
      usage = usage_from(response)

      # Empty content with a length stop is the reasoning trap: the model spent the
      # budget thinking. Say so, rather than handing the caller a blank string that
      # will fail much further downstream as "the model wrote nothing useful".
      if content.strip.empty?
        return failure(
          "#{provider} no devolvió contenido " \
                                 "(finish=#{choice["finish_reason"]}, razonamiento=#{usage[:reasoning_tokens]})"
        )
      end

      cost = provider.cost_for(input_tokens: usage[:input_tokens].to_i, output_tokens: usage[:output_tokens].to_i)
      success(content: content, finish_reason: choice["finish_reason"], cost_usd: cost, **usage)
    end

    # DeepSeek counts its reasoning inside completion_tokens and says how much of it there
    # was. Gemini's compatibility layer leaves thinking out of completion_tokens and only
    # in total_tokens — measured 2026-09-26 on a generation prompt: gemini-3.8-flash
    # reported 2,473 completion tokens of a 10,670 total, 6,134 of them thinking — yet
    # bills it as output ("Output price (including thinking tokens)"). Counting only
    # completion_tokens priced its runs at a third of the bill.
    def usage_from(response)
      usage = response["usage"] || {}
      input = usage["prompt_tokens"].to_i
      completion = usage["completion_tokens"].to_i
      unreported = usage["total_tokens"].to_i - input - completion
      reasoning = unreported.positive? ? unreported : usage.dig("completion_tokens_details", "reasoning_tokens").to_i
      { input_tokens: input, output_tokens: completion + [unreported, 0].max, reasoning_tokens: reasoning }
    end
  end
end
