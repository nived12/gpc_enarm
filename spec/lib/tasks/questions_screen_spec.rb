require "rails_helper"
require "rake"

RSpec.describe "questions:screen" do
  before(:context) do
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/questions.rake")
  end

  around do |example|
    ENV["LLM_API_KEY"] = ENV["LLM_VERIFIER_API_KEY"] = "sk-test"
    example.run
  ensure
    ENV.delete("LLM_API_KEY")
    ENV.delete("LLM_VERIFIER_API_KEY")
  end

  def unscreened(catalog_key, screened_at: nil)
    guideline = create(:guideline, catalog_key: catalog_key, enarm_relevance: nil, screened_at: screened_at)
    create(:recommendation, guideline_section: create(:guideline_section, guideline: guideline), decision_kind: nil)
    guideline
  end

  def run(task, *arguments)
    Rake::Task[task].execute(Rake::TaskArguments.new(%i[count], arguments))
  end

  def result(success:)
    errors = ActiveModel::Errors.new(Guideline.new).tap { |e| e.add(:base, "sin respuesta") } unless success
    ApplicationService::Response.new(success: success, errors: errors, payload: { relevance: nil, labelled: {} })
  end

  it "takes the guidelines never tried first, and records the run" do
    tried = unscreened("IMSS-001-22", screened_at: 1.hour.ago)
    fresh = unscreened("IMSS-002-22")
    allow(Questions::SourceScreener).to receive(:call).and_return(result(success: true))

    expect { run("questions:screen", "1") }.to output(/IMSS-002-22.*Pendientes: 2 guías/m).to_stdout

    expect(Questions::SourceScreener).to have_received(:call).with(fresh, run: kind_of(GenerationRun))
    expect(Questions::SourceScreener).not_to have_received(:call).with(tried, anything)
    expect(GenerationRun.purpose_screening.sole).to be_status_completed
  end

  it "stops after three failures in a row, without retrying" do
    4.times { |index| unscreened("IMSS-00#{index}-22") }
    allow(Questions::SourceScreener).to receive(:call).and_return(result(success: false))

    expect { run("questions:screen", "10") }.to output(/sin respuesta.*no se reintentó/m).to_stdout

    expect(Questions::SourceScreener).to have_received(:call).exactly(3).times
    expect(GenerationRun.purpose_screening.sole).to be_status_failed
  end

  it "refuses to generate while a guideline is unscreened" do
    unscreened("IMSS-001-22")

    expect { run("questions:generate") }.to raise_error(SystemExit).and output(/questions:screen\[1\]/).to_stderr
  end

  it "warns that an estimate covers only what was screened" do
    unscreened("IMSS-001-22")
    allow(Questions::CostEstimator).to receive(:call).and_return(
      ApplicationService::Response.new(success: false, errors: ActiveModel::Errors.new(Guideline.new), payload: nil)
    )

    expect { run("questions:estimate") }.to raise_error(SystemExit).and output(/Aviso: 1 guías sin revisar/).to_stdout
  end
end
