require "rails_helper"

RSpec.describe Questions::BestAvailableVerifier do
  let(:version) do
    create(:published_case, questions_count: 1, best_available: true).questions.sole.best_available_variant
  end

  def stub_model(payload, success: true)
    allow(Llm::Completion).to receive(:call).and_return(
      ApplicationService::Response.new(
        success: success, errors: (success ? nil : "sin conexión"),
        payload: { content: payload.is_a?(String) ? payload : payload.to_json,
                   input_tokens: 500, output_tokens: 60, reasoning_tokens: 0, cost_usd: 0.0002 }
      )
    )
  end

  it "supports a version only when the blind answer lands on its marked option and one clearly stands out" do
    stub_model({ "option" => "a", "clear" => true, "note" => " La troponina  orienta. " })
    run = create(:generation_run, purpose: "verification")

    expect(described_class.call(version, run: run).payload).to eq(verdict: "supported")
    expect(version.reload).to have_attributes(
      best_available_verdict: "supported",
      best_available_note: "La troponina orienta."
    )
    expect(run.reload.attempts).to eq(1)
    expect(Llm::Completion).to have_received(:call).with(
      hash_including(role: :verifier, prompt: a_string_including("NO\nestá entre las opciones", "A) Troponina I"))
    )
  end

  it "disputes a different clear choice, and leaves an unclear or unreadable one ambiguous" do
    { { "option" => "B", "clear" => true } => "disputed", { "option" => "A", "clear" => false } => "ambiguous",
      { "option" => "Z", "clear" => true } => "ambiguous" }.each do |judgement, verdict|
      stub_model(judgement)

      expect(described_class.call(version).payload).to eq(verdict: verdict)
    end
    expect(version.reload.best_available_note).to be_nil
  end

  it "fails on an unreadable reply or a failed call, and leaves the version unjudged" do
    version.update!(best_available_verdict: nil)
    stub_model("no es JSON")
    expect(described_class.call(version).errors.full_messages.first).to include("JSON legible")

    stub_model("", success: false)
    expect(described_class.call(version)).to be_failure
    expect(version.reload.best_available_verdict).to be_nil
  end
end
