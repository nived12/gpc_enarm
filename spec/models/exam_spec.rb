require "rails_helper"

RSpec.describe Exam do
  let(:user) { create(:user) }

  def build_exam(**attributes)
    create(:exam, user: user, **attributes)
  end

  describe "the clock" do
    it "adds the running stretch to what was banked, and nothing while stopped" do
      freeze_time
      running = build_exam(elapsed_seconds: 30, running_since: 45.seconds.ago)
      stopped = build_exam(elapsed_seconds: 30, running_since: nil, status: "paused")

      expect([running.current_elapsed, stopped.current_elapsed]).to eq([75, 30])
    end

    it "banks the time on pause and restarts it on resume, so a pause costs nothing" do
      freeze_time
      exam = build_exam(running_since: Time.current)

      travel 90.seconds
      exam.pause!
      travel 1.hour
      expect(exam.reload.current_elapsed).to eq(90)

      exam.resume!
      travel 10.seconds
      expect(exam.current_elapsed).to eq(100)
    end

    it "ignores a pause or resume that makes no sense for the state it is in" do
      paused = build_exam(status: "paused", running_since: nil, elapsed_seconds: 12)
      running = build_exam(running_since: Time.current)

      expect { paused.pause! }.not_to change { paused.reload.attributes }
      expect { running.resume! }.not_to change { running.reload.attributes }
    end

    it "counts down only on a timed exam, and is up at zero" do
      freeze_time
      timed = build_exam(mode: "full_exam", time_limit_seconds: 60, running_since: 60.seconds.ago)
      untimed = build_exam(running_since: 1.day.ago)

      expect([timed.remaining_seconds, timed.time_up?]).to eq([0, true])
      expect([untimed.remaining_seconds, untimed.time_up?]).to eq([nil, false])
    end

    it "gives only a timed rehearsal of the real exam its twenty-minute warning" do
      expect(build_exam(mode: "full_exam", time_limit_seconds: 60).final_warning_seconds).to eq(1200)
      expect(build_exam(mode: "full_exam").final_warning_seconds).to be_nil
      expect(build_exam(mode: "quick_quiz", time_limit_seconds: 60).final_warning_seconds).to be_nil
    end
  end

  describe "#discard!" do
    it "stops the clock and hides the exam, but keeps its rows" do
      freeze_time
      exam = build_exam(running_since: 30.seconds.ago)

      exam.discard!

      expect(exam).to have_attributes(status: "discarded", elapsed_seconds: 30, running_since: nil)
      expect(described_class.kept).not_to include(exam)
      expect(described_class.unfinished).not_to include(exam)
    end

    it "discards a finished exam too, keeping its score and time" do
      finished = build_exam(status: "completed", score: 50, elapsed_seconds: 600, running_since: nil)

      finished.discard!

      expect(finished.reload).to have_attributes(status: "discarded", score: 50, elapsed_seconds: 600)
    end

    it "is never scored or discarded twice" do
      discarded = build_exam(status: "discarded", running_since: nil)

      expect { discarded.complete! }.not_to change { discarded.reload.updated_at }
      expect { discarded.discard! }.not_to change { discarded.reload.updated_at }
    end
  end

  describe "#complete!" do
    it "scores a plain percentage in which a blank counts as a miss" do
      exam = build_exam(question_count: 3, running_since: 2.minutes.ago)
      2.times { |index| answer(exam, position: index + 1, correct: true) }
      exam.exam_questions.create!(question: create(:question), clinical_case: create(:clinical_case), position: 3)

      exam.complete!

      expect(exam).to have_attributes(status: "completed", score: BigDecimal("66.67"), running_since: nil)
      expect(exam.elapsed_seconds).to be >= 120
    end

    it "never rescores a finished exam" do
      exam = build_exam(status: "completed", score: 40, running_since: nil)

      expect { exam.complete! }.not_to change { exam.reload.score }
    end
  end

  it "starts the exam-length modes at the real exam's conditions, and practice at a gentler one" do
    expect(
      %w[full_exam extended_exam].map do |mode|
        described_class.default_feedback_timing(mode)
      end
    ).to all(eq("at_end"))
    expect(%w[quick_quiz custom].map { |mode| described_class.default_feedback_timing(mode) }).to all(eq("after_each"))
    expect(described_class.default_seconds_per_question("full_exam")).to eq(75)
    expect(described_class.default_seconds_per_question("custom")).to be_nil
  end

  it "only takes a pace the form offers" do
    expect(build(:exam, seconds_per_question: 33)).not_to be_valid
  end

  it "tallies each specialty in the order CIFRHS breaks ties by" do
    exam = build_exam(question_count: 3)
    pediatrics = create(:specialty, name: "Pediatría", position: 2)
    internal = create(:specialty, name: "Medicina Interna", position: 1)
    answer(exam, position: 1, correct: true, specialty: pediatrics)
    answer(exam, position: 2, correct: false, specialty: internal)
    answer(exam, position: 3, correct: true, specialty: internal)
    orphan = create(:clinical_case)
    exam.exam_questions.create!(question: create(:question, clinical_case: orphan), clinical_case: orphan, position: 4)

    expect(exam.tally_by_specialty).to eq([[internal, 1, 2], [pediatrics, 1, 1]])
  end

  it "tallies a question under its case's setting too, and once where subject and setting agree" do
    exam = build_exam(question_count: 2)
    internal = create(:specialty, name: "Medicina Interna", position: 1)
    emergency = create(:emergency_setting, position: 6)
    answer(exam, position: 1, correct: true, specialty: internal)
    answer(exam, position: 2, correct: false, specialty: emergency)
    exam.exam_questions.each { |exam_question| exam_question.clinical_case.update!(setting: emergency) }

    expect(exam.tally_by_specialty).to eq([[internal, 1, 1], [emergency, 1, 2]])
  end

  it "knows where the student is: the first question without an answer" do
    exam = build_exam(question_count: 2)
    answer(exam, position: 1, correct: true)
    second = exam.exam_questions.create!(
      question: create(:question), clinical_case: create(:clinical_case),
      position: 2
    )

    expect(exam.current_question).to eq(second)
    expect(exam.exam_questions.first.next_in_exam).to eq(second)
    expect(second.next_in_exam).to be_nil
  end

  it "leads on to the next question without an answer, coming round to the ones skipped" do
    exam = build_exam(question_count: 3)
    open = [1, 3].to_h do |position|
      [position, exam.exam_questions.create!(
        question: create(:question), clinical_case: create(:clinical_case),
        position: position
      )]
    end
    answer(exam, position: 2, correct: true)

    expect(exam.unanswered_after(1)).to eq(open[3])
    expect(exam.unanswered_after(3)).to eq(open[1])
    expect(exam.unanswered_after(2)).to eq(open[3])
  end

  def answer(exam, position:, correct:, specialty: nil)
    kase = create(:clinical_case, specialty: specialty)
    exam_question = exam.exam_questions.create!(
      question: create(:question, clinical_case: kase), clinical_case: kase, position: position
    )
    exam_question.create_answer!(correct: correct, answered_at: Time.current)
  end
end
