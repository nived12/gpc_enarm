require "rails_helper"

RSpec.describe Llm::Completion do
  let(:endpoint) { "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" }
  let(:deepseek) { "https://api.deepseek.com/chat/completions" }

  def with_key
    ENV["LLM_API_KEY"] = "sk-test"
    yield
  ensure
    ENV.delete("LLM_API_KEY")
  end

  def body_of(request)
    JSON.parse(request.body)
  end

  def completion(content, usage: {}, finish_reason: "stop")
    { choices: [{ message: { content: content }, finish_reason: finish_reason }],
      usage: { prompt_tokens: 100, completion_tokens: 250 }.merge(usage) }.to_json
  end

  it "refuses to call without a key, rather than sending an unauthenticated request" do
    ENV.delete("LLM_API_KEY")

    result = described_class.call(role: :generator, prompt: "hola")

    expect(result).to be_failure
    expect(result.errors.full_messages.to_sentence).to include("Falta la clave")
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it "returns the content and the token counts" do
    with_key do
      stub_request(:post, endpoint).to_return(status: 200, body: completion("{\"casos\":[]}"))

      result = described_class.call(role: :generator, prompt: "hola")

      expect(result).to be_success
      expect(result.payload[:content]).to eq("{\"casos\":[]}")
      expect(result.payload[:input_tokens]).to eq(100)
      expect(result.payload[:output_tokens]).to eq(250)
      expect(result.payload[:reasoning_tokens]).to eq(0)
      expect(result.payload[:finish_reason]).to eq("stop")
    end
  end

  # 100 in at $0.25/M and 250 out at $1.50/M.
  it "prices the call from the model's published rates" do
    with_key do
      stub_request(:post, endpoint).to_return(status: 200, body: completion("ok"))

      expect(described_class.call(role: :generator, prompt: "hola").payload[:cost_usd]).to eq(0.0004)
    end
  end

  it "reads reasoning tokens when the provider reports them" do
    with_key do
      usage = { completion_tokens: 5_682, completion_tokens_details: { reasoning_tokens: 4_638 } }
      stub_request(:post, endpoint).to_return(status: 200, body: completion("ok", usage: usage))

      result = described_class.call(role: :generator, prompt: "hola")

      expect(result.payload[:reasoning_tokens]).to eq(4_638)
    end
  end

  describe "the reasoning trap" do
    it "fails loudly when the model spent its whole budget thinking" do
      with_key do
        usage = { completion_tokens: 4_000, completion_tokens_details: { reasoning_tokens: 4_000 } }
        stub_request(:post, endpoint)
          .to_return(status: 200, body: completion("", usage: usage, finish_reason: "length"))

        result = described_class.call(role: :generator, prompt: "hola")

        expect(result).to be_failure
        expect(result.errors.full_messages.to_sentence).to include("no devolvió contenido")
        expect(result.errors.full_messages.to_sentence).to include("razonamiento=4000")
      end
    end

    it "treats whitespace-only content as empty too" do
      with_key do
        stub_request(:post, endpoint).to_return(status: 200, body: completion("   \n  "))

        expect(described_class.call(role: :generator, prompt: "hola")).to be_failure
      end
    end

    it "fails when the response carries no choices at all" do
      with_key do
        stub_request(:post, endpoint).to_return(status: 200, body: { usage: {} }.to_json)

        expect(described_class.call(role: :generator, prompt: "hola")).to be_failure
      end
    end
  end

  describe "the thinking switch" do
    it "disables thinking by default, because it is billed as output and buys nothing here" do
      ENV["LLM_VERIFIER_API_KEY"] = "sk-test"
      stub_request(:post, deepseek).to_return(status: 200, body: completion("ok"))

      described_class.call(role: :verifier, prompt: "hola")

      expect(a_request(:post, deepseek).with { |r| body_of(r)["thinking"] == { "type" => "disabled" } })
        .to have_been_made
    ensure
      ENV.delete("LLM_VERIFIER_API_KEY")
    end

    it "never sends the field to a provider that rejects unknown fields" do
      ENV["LLM_PROVIDER"] = "gemini"
      with_key do
        stub_request(:post, endpoint).to_return(status: 200, body: completion("ok"))

        described_class.call(role: :generator, prompt: "hola")

        expect(a_request(:post, endpoint).with { |r| !body_of(r).key?("thinking") }).to have_been_made
      end
    ensure
      ENV.delete("LLM_PROVIDER")
    end

    it "leaves the provider's default in place when thinking is asked for" do
      ENV["LLM_VERIFIER_API_KEY"] = "sk-test"
      stub_request(:post, deepseek).to_return(status: 200, body: completion("ok"))

      described_class.call(role: :verifier, prompt: "hola", thinking: true)

      expect(a_request(:post, deepseek).with { |r| !body_of(r).key?("thinking") }).to have_been_made
    ensure
      ENV.delete("LLM_VERIFIER_API_KEY")
    end

    it "sends the model and the token budget it was given" do
      with_key do
        stub_request(:post, endpoint).to_return(status: 200, body: completion("ok"))

        described_class.call(role: :generator, prompt: "hola", max_tokens: 1_234)

        expect(
          a_request(:post, endpoint).with do |r|
            parsed = body_of(r)
            parsed["model"] == "gemini-3.1-flash-lite" && parsed["max_tokens"] == 1_234
          end
        ).to have_been_made
      end
    end
  end

  describe "when the call does not come back" do
    it "reports the status and the body on an HTTP error" do
      with_key do
        stub_request(:post, endpoint).to_return(status: 429, body: "rate limit exceeded")

        result = described_class.call(role: :generator, prompt: "hola")

        expect(result).to be_failure
        expect(result.errors.full_messages.to_sentence).to include("429")
        expect(result.errors.full_messages.to_sentence).to include("rate limit exceeded")
      end
    end

    it "reports an unparseable body instead of failing later as a type error" do
      with_key do
        stub_request(:post, endpoint).to_return(status: 200, body: "<html>502 Bad Gateway</html>")

        result = described_class.call(role: :generator, prompt: "hola")

        expect(result).to be_failure
        expect(result.errors.full_messages.to_sentence).to include("ilegible")
      end
    end

    it "reports a network failure without raising" do
      with_key do
        stub_request(:post, endpoint).to_raise(Errno::ECONNRESET)

        result = described_class.call(role: :generator, prompt: "hola")

        expect(result).to be_failure
        expect(result.errors.full_messages.to_sentence).to include("No se pudo llamar")
      end
    end
  end

  describe ".json_in" do
    it "reads a reply fenced in markdown as well as a bare one" do
      expect(described_class.json_in("```json\n{\"a\":1}\n```")).to eq("a" => 1)
      expect(described_class.json_in(" {\"a\":1} ")).to eq("a" => 1)
    end

    it "is nil for a reply that is not JSON, or is JSON but not an object" do
      expect(described_class.json_in("No puedo ayudar con eso.")).to be_nil
      expect(described_class.json_in("[1, 2]")).to be_nil
    end
  end
end
