# Where a generation or verification request goes: which service, as which model, with
# which key.
#
# Every value has a default in code, so a forgotten environment variable degrades to a
# working choice rather than a nil surfacing deep inside a job. The API key is the one
# exception — there is no sensible default for a secret, and a run without one should
# stop somewhere it is obvious why.
#
# Generator and verifier are separate roles that default to different services on
# purpose. The verification pass exists to be a second opinion, and a model grading its
# own output is a much weaker check than another family grading it.
module Llm
  class Provider
    class UnknownProvider < StandardError; end

    # Gemini and DeepSeek both speak the OpenAI chat format, so one client serves
    # either. Gemini's compatibility layer sits under /v1beta/openai/ and the trailing
    # slash is part of the path, not decoration.
    PRESETS = {
      "gemini" => {
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai/",
        model: "gemini-3.1-flash-lite",
        # Gemini's compatibility layer rejects an unknown field outright — sending
        # `thinking` returns 400 "Unknown name". Flash-Lite reports zero reasoning
        # tokens anyway, so there is nothing to switch off.
        thinking: false
      },
      "deepseek" => {
        base_url: "https://api.deepseek.com",
        model: "deepseek-flash",
        thinking: true
      },
      "anthropic" => {
        base_url: "https://api.anthropic.com/v1",
        model: "claude-haiku-4-5-20251001",
        # Anthropic's own API is not OpenAI-shaped and spells thinking differently.
        thinking: false
      }
    }.freeze

    # USD per million tokens, input and output, read from each provider's pricing page
    # on 2026-09-22. DeepSeek halves both outside its peak hours; the peak price is kept,
    # so a spending cap errs towards stopping early. A model not listed here has no
    # known price, and a run on it is not capped by cost.
    #
    # The rest were read on 2026-09-26 for the model comparison. Gemini 3.8 Flash doubles
    # both on 2027-01-01, and 3.1 Pro's price is the one for prompts under 200k tokens,
    # which every prompt here is.
    PRICES = {
      "gemini-3.1-flash-lite" => [0.25, 1.50],
      "gemini-3.5-flash-lite" => [0.30, 2.50],
      "gemini-3.8-flash" => [0.75, 3.75],
      "gemini-3.1-pro-preview" => [2.00, 12.00],
      "deepseek-flash" => [0.30, 1.20],
      "deepseek-v4-pro" => [1.32, 3.96]
    }.freeze

    ROLES = {
      generator: { provider: "gemini", prefix: "LLM" },
      verifier: { provider: "deepseek", prefix: "LLM_VERIFIER" }
    }.freeze

    attr_reader :role, :name, :model, :base_url, :api_key, :reasoning_effort

    def self.for(role)
      defaults = ROLES.fetch(role)
      new(role: role, prefix: defaults[:prefix], fallback: defaults[:provider])
    end

    def self.all
      ROLES.keys.map { |role| self.for(role) }
    end

    # Read at call time rather than at class-definition time: a constant captured on
    # load cannot be changed by a spec, and dotenv has not necessarily run yet.
    def initialize(role:, prefix:, fallback:)
      @role = role
      @prefix = prefix
      @name = env("PROVIDER") || fallback
      # Resolved once, and before the overrides are read: a misspelled provider must
      # fail even when MODEL and BASE_URL happen to be set and would mask it.
      preset = PRESETS.fetch(@name) do
        raise UnknownProvider, "#{prefix}_PROVIDER=#{@name.inspect} is not one of #{PRESETS.keys.join(", ")}"
      end
      @model = env("MODEL") || preset.fetch(:model)
      @base_url = env("BASE_URL") || preset.fetch(:base_url)
      @api_key = env("API_KEY")
      # How long a thinking model thinks: minimal, low, medium or high, sent as
      # `reasoning_effort`, which Gemini maps to its thinking_level. Unset leaves the
      # model's default — for gemini-3.8-flash about 6,000 billed tokens a generation call.
      @reasoning_effort = env("REASONING_EFFORT")
      @supports_thinking = preset.fetch(:thinking)
    end

    # Whether this service understands the `thinking` request field at all. Not every
    # provider ignores what it does not know: Gemini answers 400.
    def supports_thinking?
      @supports_thinking
    end

    def configured?
      api_key.present?
    end

    def to_s
      "#{name}/#{model}"
    end

    def priced?
      PRICES.key?(model)
    end

    def cost_for(input_tokens:, output_tokens:)
      input_price, output_price = PRICES.fetch(model, [0, 0])
      ((input_tokens * input_price) + (output_tokens * output_price)) / 1_000_000.0
    end

    private

    attr_reader :prefix

    def env(suffix)
      ENV["#{prefix}_#{suffix}"].presence
    end
  end
end
