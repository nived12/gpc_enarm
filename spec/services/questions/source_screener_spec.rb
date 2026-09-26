require "rails_helper"

RSpec.describe Questions::SourceScreener do
  let(:guideline) { create(:guideline, title: "Rehabilitación de la fractura de cadera", enarm_relevance: nil) }
  let(:section) do
    create(
      :guideline_section, guideline: guideline, kind: "recommendation",
      clinical_question: "¿Cuándo iniciar la movilización tras la cirugía?"
    )
  end
  let!(:statements) do
    [
      "Se recomienda iniciar la movilización en las primeras 48 horas.",
      "Se recomienda una férula a 20 grados de abducción.",
      "Se recomienda registrar la escala en el expediente."
    ].map { |text| create(:recommendation, guideline_section: section, text: text, decision_kind: nil) }
  end

  def reply(payload)
    ApplicationService::Response.new(
      success: true, errors: nil,
      payload: { content: payload.is_a?(String) ? payload : payload.to_json,
                 input_tokens: 2_000, output_tokens: 40, reasoning_tokens: 0, cost_usd: 0.00065 }
    )
  end

  def stub_replies(*payloads)
    replies = payloads.map { |payload| reply(payload) }
    allow(Llm::Completion).to receive(:call) do |**arguments|
      prompts_sent << arguments[:prompt]
      replies.shift
    end
  end

  def kinds = statements.map { |statement| statement.reload.decision_kind }

  def prompts_sent
    @prompts_sent ||= []
  end

  it "rates the guideline, then labels each statement, as the verifier role" do
    stub_replies(
      { "relevance" => "Secondary", "note" => "Se pregunta la fractura, no su rehabilitación." },
      { "1" => "gp", "2" => "specialist", "3" => "process" }
    )
    run = create(:generation_run, purpose: "screening")

    result = described_class.call(guideline, run: run)

    expect(result).to be_success
    expect(result.payload).to eq(
      relevance: "secondary", labelled: { "general_practice" => 1, "specialist" => 1, "process" => 1 }
    )
    expect(guideline.reload).to have_attributes(
      enarm_relevance: "secondary", relevance_note: "Se pregunta la fractura, no su rehabilitación."
    )
    expect(kinds).to eq(%w[general_practice specialist process])
    expect(Llm::Completion).to have_received(:call).with(hash_including(role: :verifier)).twice
    expect(run.reload.calls).to eq(2)
  end

  it "shows the model the title, the guideline's questions, and its statements numbered" do
    stub_replies({ "relevance" => "core" }, {})

    described_class.call(guideline)

    relevance, labels = prompts_sent
    expect(relevance).to include(guideline.title, "¿Cuándo iniciar la movilización", "férula a 20 grados")
    expect(labels).to include("1. Se recomienda iniciar", "3. Se recomienda registrar")
  end

  it "stops at the rating when the guideline is out of scope" do
    stub_replies("relevance" => "out_of_scope", "note" => "Rehabilitación.")

    result = described_class.call(guideline)

    expect(result.payload[:labelled]).to be_empty
    expect(Llm::Completion).to have_received(:call).once
    expect(kinds).to all(be_nil)
  end

  it "asks only what is still unknown" do
    guideline.update!(enarm_relevance: "core")
    statements.first.update!(decision_kind: "general_practice")
    stub_replies("1" => "process", "2" => "gp")

    described_class.call(guideline)

    expect(prompts_sent.sole).not_to include("iniciar la movilización")
    expect(kinds).to eq(%w[general_practice process general_practice])
  end

  it "asks a slice of statements at a time" do
    guideline.update!(enarm_relevance: "core")
    stub_const("#{described_class}::STATEMENTS_PER_CALL", 2)
    stub_replies({ "1" => "gp", "2" => "gp" }, { "1" => "process" })

    described_class.call(guideline)

    expect(kinds).to eq(%w[general_practice general_practice process])
  end

  it "sends only the opening of a statement the parser could not split" do
    guideline.update!(enarm_relevance: "core")
    statements.first.update!(text: "Se recomienda #{"movilizar " * 200}")
    stub_replies({})

    described_class.call(guideline)

    expect(prompts_sent.sole.length).to be < 2_500
  end

  # Left unscreened, the statement is not generated from and is asked again next time.
  it "stores no label the model left out or misspelled" do
    guideline.update!(enarm_relevance: "core")
    stub_replies("1" => "general", "3" => "process", "4" => "gp")

    result = described_class.call(guideline)

    expect(result).to be_success
    expect(kinds).to eq([nil, nil, "process"])
  end

  it "fails on a rating it does not know, and labels nothing" do
    stub_replies("relevance" => "high")

    result = described_class.call(guideline)

    expect(result).to be_failure
    expect(result.errors.full_messages.to_sentence).to include("no es una de las previstas")
    expect(guideline.reload.enarm_relevance).to be_nil
    expect(Llm::Completion).to have_received(:call).once
  end

  it "fails on a reply that is not a JSON object" do
    stub_replies("No puedo clasificar eso.")

    expect(described_class.call(guideline).errors.full_messages.to_sentence).to include("JSON legible")
  end

  it "keeps what earlier slices labelled when a later call fails" do
    guideline.update!(enarm_relevance: "core")
    stub_const("#{described_class}::STATEMENTS_PER_CALL", 2)
    errors = ActiveModel::Errors.new(Guideline.new).tap { |e| e.add(:base, "deepseek respondió 402") }
    allow(Llm::Completion).to receive(:call).and_return(
      reply("1" => "gp", "2" => "gp"), ApplicationService::Response.new(success: false, payload: nil, errors: errors)
    )

    result = described_class.call(guideline)

    expect(result.errors.full_messages.to_sentence).to include("402")
    expect(result.payload[:labelled]).to eq("general_practice" => 2)
    expect(statements.last.reload.decision_kind).to be_nil
  end
end
