require "rails_helper"
require "rake"

RSpec.describe "gpc statement repair tasks" do
  before(:context) do
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/gpc.rake")
  end

  around do |example|
    ENV["LLM_API_KEY"] = ENV["LLM_VERIFIER_API_KEY"] = "sk-test"
    example.run
  ensure
    ENV.delete("LLM_API_KEY")
    ENV.delete("LLM_VERIFIER_API_KEY")
  end

  let(:section) { create(:guideline_section, kind: "recommendation") }

  def run(task, *arguments)
    Rake::Task[task].execute(Rake::TaskArguments.new(%i[count], arguments))
  end

  def result(success:)
    errors = ActiveModel::Errors.new(Recommendation.new).tap { |e| e.add(:base, "sin respuesta") } unless success
    ApplicationService::Response.new(
      success: success, errors: errors, payload: { read: success ? 1 : 0, repaired: 0, damaged: 0, refused: 0 }
    )
  end

  describe "gpc:repair_statements" do
    it "reads the pending actionable statements a batch at a time, and records the run" do
      pending = create(:recommendation, guideline_section: section)
      create(:recommendation, guideline_section: section, repaired_at: 1.day.ago)
      create(:recommendation, guideline_section: create(:guideline_section, kind: "evidence"))
      allow(Gpc::StatementRepairer).to receive(:call).and_return(result(success: true))

      expect { run("gpc:repair_statements") }.to output(/1 leídas.*read=1 .*pendientes 1/m).to_stdout

      expect(Gpc::StatementRepairer).to have_received(:call).with([pending], run: an_instance_of(GenerationRun))
      expect(GenerationRun.last).to have_attributes(purpose: "statement_repair", status: "completed")
    end

    it "stops after three failures in a row, and does not retry" do
      Array.new(4) { create(:recommendation, guideline_section: section, text: "Se recomienda #{"vigilar " * 1_100}") }
      allow(Gpc::StatementRepairer).to receive(:call).and_return(result(success: false))

      expect { run("gpc:repair_statements", "4") }.to output(/sin respuesta.*Detenida tras 3 fallas/m).to_stdout

      expect(Gpc::StatementRepairer).to have_received(:call).exactly(3).times
      expect(GenerationRun.last).to be_status_failed
    end

    it "refuses to start without the verifier's key" do
      ENV.delete("LLM_API_KEY")
      ENV.delete("LLM_VERIFIER_API_KEY")

      expect { run("gpc:repair_statements") }.to raise_error(SystemExit).and output(/Falta la clave/).to_stderr
    end
  end

  describe "gpc:export_repairs and gpc:import_repairs" do
    let(:path) { Rails.root.join("tmp/test-repairs-task-#{SecureRandom.hex(4)}.jsonl.gz").to_s }

    after { FileUtils.rm_f(path) }

    def run_with_path(task, value)
      Rake::Task[task].execute(Rake::TaskArguments.new(%i[path], [value]))
    end

    it "writes the repairs and applies them back" do
      create(:recommendation, guideline_section: section, clean_text: "Limpia.", repaired_at: 1.day.ago)

      expect { run_with_path("gpc:export_repairs", path) }.to output(/1 recomendaciones/).to_stdout
      expect { run_with_path("gpc:import_repairs", path) }.to output(/aplicadas 1 · sin encontrar 0/).to_stdout
    end

    it "stops on a missing file" do
      expect { run_with_path("gpc:import_repairs", path) }.to raise_error(SystemExit).and output(/No existe/).to_stderr
    end
  end
end
