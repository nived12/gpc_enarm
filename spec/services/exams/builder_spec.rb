require "rails_helper"

RSpec.describe Exams::Builder do
  let(:user) { create(:user) }
  let(:internal) { create(:specialty, name: "Medicina Interna", position: 1) }
  let(:pediatrics) { create(:specialty, name: "Pediatría", position: 2) }

  def build(mode: "custom", filters: {}, seed: 1)
    described_class.call(user: user, mode: mode, filters: filters, random: Random.new(seed))
  end

  def cases_in(exam)
    exam.exam_questions.map(&:clinical_case).uniq
  end

  it "draws only published cases — never a draft, an unsupported or a withdrawn one" do
    live = create(:published_case)
    create(:clinical_case, verification_verdict: "supported")
    create(:clinical_case, verification_verdict: "supported", status: "retired")

    exam = build.payload[:exam]

    expect(cases_in(exam)).to eq([live])
  end

  it "builds nothing for a free student who has used today's allowance" do
    user.update_column(:trial_ends_at, 1.day.ago)
    allow(SubscriptionAccess).to receive(:free_daily_questions).and_return(0)
    create(:published_case)

    result = build(mode: "quick_quiz")

    expect(result.errors.of_kind?(:base, :daily_limit_reached)).to be(true)
    expect(result.errors.full_messages).to eq([I18n.t("exams.denied.daily_limit_reached", limit: 0)])
    expect(Exam.count).to eq(0)
  end

  it "takes whole cases, in their own question order, and records how many questions it drew" do
    kase = create(:published_case, questions_count: 3)

    exam = build(mode: "quick_quiz").payload[:exam]

    expect(exam.exam_questions.map(&:question)).to eq(kase.questions.to_a)
    expect(exam).to have_attributes(
      question_count: 3, mode: "quick_quiz", time_limit_seconds: nil,
      filters: { "interleave" => true }
    )
    expect(exam.exam_questions.map(&:position)).to eq([1, 2, 3])
  end

  it "draws exactly the number asked for, from whole cases" do
    3.times { create(:published_case, questions_count: 3) }
    2.times { create(:published_case, questions_count: 2) }

    (5..10).each do |count|
      expect(build(filters: { question_count: count }, seed: count).payload[:exam].question_count).to eq(count)
    end
  end

  it "keeps to the bank's own mix of two- and three-question cases" do
    6.times { create(:published_case, questions_count: 3) }
    6.times { create(:published_case, questions_count: 2) }

    exam = build(filters: { question_count: 15 }).payload[:exam]

    sizes = cases_in(exam).map { |kase| kase.questions.count }.tally
    expect(exam.question_count).to eq(15)
    expect(sizes).to eq(3 => 3, 2 => 3)
  end

  it "runs over by as little as a case allows only when nothing adds up exactly" do
    4.times { create(:published_case, questions_count: 3) }

    exam = build(filters: { question_count: 5 }).payload[:exam]

    expect(exam.question_count).to eq(6)
  end

  it "gives what there is when the bank is smaller than the exam" do
    create(:published_case, questions_count: 3)

    expect(build(filters: { question_count: 10 }).payload[:exam].question_count).to eq(3)
  end

  it "gives the exam-length modes the real exam's conditions unless the student changes them" do
    create(:published_case, questions_count: 2)

    exam = build(mode: "full_exam").payload[:exam]

    expect(exam).to have_attributes(
      question_count: 2, feedback_timing: "at_end", seconds_per_question: 75, time_limit_seconds: 150
    )
  end

  describe "the real exam's difficulty mix" do
    before { stub_const("Exam::QUESTION_COUNTS", Exam::QUESTION_COUNTS.merge("full_exam" => 8)) }

    def questions_by_level(exam)
      exam.exam_questions.includes(:clinical_case).map { |row| row.clinical_case.difficulty }.tally
    end

    it "draws a quarter low, half medium and a quarter high on an exam-length mode, exactly" do
      %w[low medium high].each do |level|
        2.times { create(:published_case, difficulty: level, questions_count: 3) }
        2.times { create(:published_case, difficulty: level, questions_count: 2) }
      end

      exam = build(mode: "full_exam").payload[:exam]

      expect(questions_by_level(exam)).to eq("low" => 2, "medium" => 4, "high" => 2)
    end

    it "falls back to the plain draw when the bank is short of a level" do
      8.times { create(:published_case, difficulty: "low", questions_count: 1) }
      create(:published_case, difficulty: "high", questions_count: 1)

      exam = build(mode: "full_exam").payload[:exam]

      expect([exam.question_count, questions_by_level(exam)["high"]]).to eq([8, nil]).or eq([8, 1])
    end

    # Three-question cases cannot make a level of two; taking that level alone would run
    # the exam over, so the plain draw, which mixes sizes across levels, decides.
    it "falls back to the plain draw when a level's case sizes cannot add up to its count" do
      %w[low high].each { |level| 2.times { create(:published_case, difficulty: level, questions_count: 3) } }
      4.times { create(:published_case, difficulty: "medium", questions_count: 1) }

      exam = build(mode: "full_exam").payload[:exam]

      expect(exam.question_count).to eq(8)
    end

    it "splits a longer exam with the remainder in the middle" do
      stub_const("Exam::QUESTION_COUNTS", Exam::QUESTION_COUNTS.merge("extended_exam" => 10))
      %w[low medium high].each { |level| 6.times { create(:published_case, difficulty: level, questions_count: 1) } }

      exam = build(mode: "extended_exam").payload[:exam]

      expect(questions_by_level(exam)).to eq("low" => 3, "medium" => 4, "high" => 3)
    end
  end

  it "takes the student's own conditions, where no clock at all is a choice" do
    create(:published_case, questions_count: 2)

    exam = described_class.call(
      user: user, mode: "full_exam", settings: { feedback_timing: "after_each", seconds_per_question: "" }
    ).payload[:exam]

    expect(exam).to have_attributes(feedback_timing: "after_each", seconds_per_question: nil, time_limit_seconds: nil)
  end

  it "sits Modo ENARM only on an exam-length mode, with its answers read back at the end" do
    create(:published_case, questions_count: 2)
    settings = { enarm_mode: "1", feedback_timing: "after_each" }

    mock = described_class.call(user: user, mode: "full_exam", settings: settings).payload[:exam]
    quiz = described_class.call(user: user, mode: "custom", settings: settings).payload[:exam]

    expect([mock.enarm_mode, mock.feedback_timing]).to eq([true, "at_end"])
    expect([quiz.enarm_mode, quiz.feedback_timing]).to eq([false, "after_each"])
  end

  it "falls back to the mode's timing for a value the form never offers" do
    create(:published_case)

    exam = described_class.call(user: user, mode: "custom", settings: { feedback_timing: "never" }).payload[:exam]

    expect(exam).to be_feedback_after_each
  end

  it "deals specialties in turn, so consecutive cases rarely share one" do
    3.times { create(:published_case, specialty: internal, questions_count: 1) }
    3.times { create(:published_case, specialty: pediatrics, questions_count: 1) }

    exam = build(filters: { question_count: 6 }).payload[:exam]

    specialties = cases_in(exam).map(&:specialty_id)
    expect(specialties.each_cons(2).none? { |a, b| a == b }).to be(true)
  end

  it "blocks by specialty, in reading order, when the student opts out of interleaving" do
    2.times { create(:published_case, specialty: pediatrics, questions_count: 1) }
    2.times { create(:published_case, specialty: internal, questions_count: 1) }

    exam = build(filters: { question_count: 10, interleave: "0" }).payload[:exam]

    expect(cases_in(exam).map(&:specialty)).to eq([internal, internal, pediatrics, pediatrics])
    expect(exam.filters).to include("interleave" => false)
  end

  it "narrows to the specialties, topic and difficulties chosen" do
    topic = create(:topic)
    wanted = create(:published_case, specialty: internal, topic: topic, difficulty: "high")
    create(:published_case, specialty: pediatrics, topic: topic, difficulty: "high")
    create(:published_case, specialty: internal, difficulty: "high")
    create(:published_case, specialty: internal, topic: topic, difficulty: "low")

    filters = { specialty_ids: ["", internal.id.to_s], topic_ids: ["", topic.id.to_s], difficulties: %w[high bogus] }
    exam = build(filters: filters)

    expect(cases_in(exam.payload[:exam])).to eq([wanted])
    expect(exam.payload[:exam].filters).to include(
      "specialty_ids" => [internal.id], "topic_ids" => [topic.id], "difficulties" => %w[high]
    )
  end

  describe "a specialty filter that is an area" do
    let(:emergency) { create(:emergency_setting, position: 6) }
    let!(:internal_in_emergency) do
      create(:published_case, specialty: internal, setting: emergency, questions_count: 1)
    end
    let!(:emergency_in_emergency) do
      create(:published_case, specialty: emergency, setting: emergency, questions_count: 1)
    end
    let!(:emergency_unknown) { create(:published_case, specialty: emergency, setting: nil, questions_count: 1) }
    let!(:internal_unknown) { create(:published_case, specialty: internal, setting: nil, questions_count: 1) }

    it "draws the cases about Urgencias and the cases set in urgencias" do
      exam = build(filters: { specialty_ids: [emergency.id] }).payload[:exam]

      expect(cases_in(exam)).to contain_exactly(internal_in_emergency, emergency_in_emergency, emergency_unknown)
    end

    it "never draws a case twice when a troncal and a context are picked together" do
      exam = build(filters: { specialty_ids: [internal.id, emergency.id] }).payload[:exam]

      expect(exam.exam_questions.map(&:clinical_case_id).tally.values).to all(eq(1))
      expect(cases_in(exam))
        .to contain_exactly(internal_in_emergency, emergency_in_emergency, emergency_unknown, internal_unknown)
    end

    # A guideline with no main topic leaves its cases with no subject; where they happen
    # still files them.
    it "draws a case with no subject from the context it is set in" do
      unfiled = create(:published_case, specialty: nil, topic: nil, setting: emergency, questions_count: 1)

      expect(cases_in(build(filters: { specialty_ids: [emergency.id] }).payload[:exam])).to include(unfiled)
    end

    it "leaves a troncal's filter to what the case is about" do
      exam = build(filters: { specialty_ids: [internal.id] }).payload[:exam]

      expect(cases_in(exam)).to contain_exactly(internal_in_emergency, internal_unknown)
    end

    it "keeps withdrawn cases out whatever their setting" do
      internal_in_emergency.update!(status: "retired")

      expect(cases_in(build(filters: { specialty_ids: [emergency.id] }).payload[:exam]))
        .to contain_exactly(emergency_in_emergency, emergency_unknown)
    end

    # A study day in a context: its topics, or anything set in the context.
    it "widens a topic filter with the cases set in a context" do
      topic = create(:topic)
      on_topic = create(:published_case, specialty: pediatrics, topic: topic, questions_count: 1)

      exam = build(filters: { topic_ids: [topic.id], also_setting_ids: [emergency.id] }).payload[:exam]

      expect(cases_in(exam)).to contain_exactly(on_topic, internal_in_emergency, emergency_in_emergency)
      expect(exam.filters).to include("also_setting_ids" => [emergency.id])
    end

    it "puts the day's own topics first when the context has more than the quiz holds" do
      topic = create(:topic)
      on_topic = create(:published_case, specialty: pediatrics, topic: topic, questions_count: 1)
      30.times { create(:published_case, specialty: pediatrics, setting: emergency, questions_count: 1) }

      (1..10).each do |seed|
        exam = build(
          filters: { topic_ids: [topic.id], also_setting_ids: [emergency.id], question_count: 5 },
          seed: seed
        )
          .payload[:exam]
        expect(cases_in(exam)).to include(on_topic)
      end
    end

    it "draws the cases set in a context when the day's topics have none" do
      exam = build(filters: { topic_ids: [], also_setting_ids: [emergency.id] }).payload[:exam]

      expect(cases_in(exam)).to contain_exactly(internal_in_emergency, emergency_in_emergency)
    end

    it "draws exactly the cases the form counts beside the box" do
      count = ClinicalCase.status_published.count_by_area.fetch(emergency.id)
      exam = build(filters: { specialty_ids: [emergency.id], question_count: 100 }).payload[:exam]

      expect(cases_in(exam).size).to eq(count)
    end
  end

  describe "the student's own history" do
    let!(:seen) { create(:published_case, questions_count: 1) }
    let!(:unseen) { create(:published_case, questions_count: 1) }

    before do
      exam = create(:exam, user: user, question_count: 1)
      exam_question = exam.exam_questions.create!(question: seen.questions.first, clinical_case: seen, position: 1)
      exam_question.create_answer!(correct: false, answered_at: Time.current)
    end

    it "leaves out what the student has already seen" do
      expect(cases_in(build(filters: { unseen_only: "1" }).payload[:exam])).to eq([unseen])
    end

    it "brings back only what the student missed" do
      expect(cases_in(build(filters: { previously_wrong_only: "1" }).payload[:exam])).to eq([seen])
    end

    it "counts a case as seen once answered, not once drawn, discarded exams included" do
      drawn = create(:published_case, questions_count: 1)
      sit(user, drawn, [nil], finish: true)
      discarded = create(:published_case, questions_count: 1)
      sit(user, discarded, [:wrong]).discard!

      expect(cases_in(build(filters: { unseen_only: "1" }).payload[:exam])).to contain_exactly(unseen, drawn)
      expect(cases_in(build(filters: { previously_wrong_only: "1" }).payload[:exam]))
        .to contain_exactly(seen, discarded)
    end

    it "is the student's history, not anyone else's" do
      other = described_class.call(user: create(:user), mode: "custom", filters: { unseen_only: "1" })

      expect(cases_in(other.payload[:exam])).to contain_exactly(seen, unseen)
    end
  end

  it "ignores filters on a preset: those are fixed exams" do
    create(:published_case, specialty: pediatrics)

    exam = build(mode: "quick_quiz", filters: { specialty_ids: [internal.id] }).payload[:exam]

    expect(exam.question_count).to eq(2)
  end

  it "clamps the size of a custom exam to what the form offers" do
    create(:published_case)

    expect(build(filters: { question_count: 5000 }).payload[:exam].filters["question_count"]).to eq(100)
  end

  it "says so when nothing matches, rather than starting an empty exam" do
    result = build

    expect(result).to be_failure
    expect(result.errors.full_messages).to eq([I18n.t("exams.builder.nothing_matches")])
    expect(Exam.count).to eq(0)
  end

  it "refuses a mode it does not know" do
    expect(build(mode: "no_such_mode").errors.full_messages).to eq([I18n.t("exams.builder.unknown_mode")])
  end
end
