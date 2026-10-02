# One sitting: the cases drawn for it, the student's answers, and the clock.
#
# The clock is kept on the server and only runs while the exam is in progress. Time since
# `started_at` would count the night a paused exam sat in a closed tab, and "ran out of
# time" is one of the failure modes the simulator exists to rehearse.
class Exam < ApplicationRecord
  belongs_to :user

  has_many :exam_questions, -> { order(:position) }, dependent: :destroy, inverse_of: :exam
  has_many :answers, through: :exam_questions

  enum :mode,
    {
      quick_quiz: "quick_quiz", custom: "custom", full_exam: "full_exam", extended_exam: "extended_exam",
      review: "review", weak_spots: "weak_spots"
    },
    prefix: :mode

  enum :status,
    { in_progress: "in_progress", paused: "paused", completed: "completed", discarded: "discarded" },
    prefix: :status

  # Practice modes explain each answer as soon as it is given, one question at a time.
  # With explanations at the end the whole exam is one scrolling page, as the real one is:
  # every case on screen, answers changeable until the student finishes.
  enum :feedback_timing, { after_each: "after_each", at_end: "at_end" }, prefix: :feedback

  # How many questions each preset asks for. The real exam is ~280 items; 450 is the
  # length it had before 2021, and some students still train on it.
  # A review session and a weak-spot quiz are twenty: long enough to matter, short
  # enough to do between consults.
  QUESTION_COUNTS = {
    "quick_quiz" => 10, "full_exam" => 280, "extended_exam" => 450, "review" => 20, "weak_spots" => 20
  }.freeze

  # The exam-length modes are rehearsals, so they default to the real exam's conditions:
  # explanations at the end and a clock. 75 seconds a question is the real sitting — six
  # hours for about 280 items — spread evenly; it is a budget for the whole exam, never a
  # limit on any one question.
  EXAM_LENGTH_MODES = %w[full_exam extended_exam].freeze
  SUGGESTED_SECONDS_PER_QUESTION = 75
  PACES = [60, 75, 90, 120].freeze

  # The real answer sheet's split, 70 low, 140 medium and 70 high of 280 (a candidate's
  # 2026 sheet). Only the exam-length modes follow it; see Exams::Builder#by_difficulty.
  DIFFICULTY_MIX = { "low" => 0.25, "medium" => 0.5, "high" => 0.25 }.freeze

  # The real sitting announces the time once, twenty minutes before the end; the
  # exam-length modes warn at the same moment.
  FINAL_WARNING_SECONDS = 20 * 60


  validates :question_count, numericality: { greater_than: 0 }
  validates :seconds_per_question, inclusion: { in: PACES }, allow_nil: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :unfinished, -> { where(status: %w[in_progress paused]) }

  # A discarded exam is gone from the student's view — history, home, average — but its
  # rows stay: its answers still count against the free daily allowance, or answering
  # and discarding would get round it, and the cases in it were still seen.
  scope :kept, -> { where.not(status: "discarded") }

  # Finishing an exam turns its blanks into misses and makes the single page's answers
  # final, so every case in it goes back into the review schedule.
  after_commit :reschedule_reviews, on: :update, if: -> { saved_change_to_status?(to: "completed") }

  # Every way an exam ends — the finish button, the clock running out on a page or on a
  # late answer — goes through complete!, so the event is sent from here and only once.
  # A review session and a weak-spot quiz are exams too, told apart by mode.
  after_commit :report_finished, on: :update, if: -> { saved_change_to_status?(to: "completed") }

  def self.default_feedback_timing(mode)
    EXAM_LENGTH_MODES.include?(mode.to_s) ? "at_end" : "after_each"
  end

  def self.default_seconds_per_question(mode)
    SUGGESTED_SECONDS_PER_QUESTION if EXAM_LENGTH_MODES.include?(mode.to_s)
  end

  def current_elapsed
    return elapsed_seconds if running_since.nil?

    elapsed_seconds + (Time.current - running_since).to_i
  end

  def remaining_seconds
    [time_limit_seconds - current_elapsed, 0].max if time_limit_seconds
  end

  # Only a timed rehearsal of the real exam gets the real sitting's one warning, and only
  # one long enough to have a moment worth warning about.
  def final_warning_seconds
    return unless EXAM_LENGTH_MODES.include?(mode) && time_limit_seconds.to_i > FINAL_WARNING_SECONDS

    FINAL_WARNING_SECONDS
  end

  def final_warning_due?
    !final_warning_seconds.nil? && remaining_seconds <= final_warning_seconds
  end

  def time_up?
    remaining_seconds&.zero? || false
  end

  def unfinished?
    status_in_progress? || status_paused?
  end

  # Any exam the student no longer wants counted, finished or not. A finished exam is
  # their own record, and a sitting ended by accident at 0% should not weigh on their
  # average forever.
  def discard!
    return if status_discarded?

    update!(status: "discarded", elapsed_seconds: current_elapsed, running_since: nil)
  end

  def pause!
    return unless status_in_progress?

    update!(status: "paused", elapsed_seconds: current_elapsed, running_since: nil)
  end

  def resume!
    return unless status_paused?

    update!(status: "in_progress", running_since: Time.current)
  end

  # Unanswered questions count against the score: on the real exam a blank is a miss.
  def complete!
    return unless unfinished?

    correct = answers.where(correct: true).count
    update!(
      status: "completed", elapsed_seconds: current_elapsed, running_since: nil, completed_at: Time.current,
      score: (100.0 * correct / question_count).round(2)
    )
  end

  # The first question without an answer, which is where the student is. Nil once every
  # question has one.
  def current_question
    exam_questions.where.missing(:answer).first
  end

  # Where "next" leads from a question: the first one after it still without an answer,
  # coming round to the start for the ones skipped earlier. Nil once none is left.
  def unanswered_after(position)
    unanswered = exam_questions.where.missing(:answer).where.not(position: position)
    unanswered.find_by("exam_questions.position > ?", position) || unanswered.first
  end

  # Correct answers against questions asked, per specialty, in the order CIFRHS breaks
  # ties by. Blanks count as asked and missed. A specialty is an area
  # (ClinicalCase.in_area): a question counts under its case's subject and its setting,
  # so the rows can add up to more than the exam — the results page says so.
  def tally_by_specialty
    counts = exam_questions.reorder(nil).joins(:clinical_case).joins(ClinicalCase::AREAS_JOIN).left_joins(:answer)
                           .group("areas.area_id")
                           .pluck("areas.area_id", Arel.sql("COUNT(*)"),
                             Arel.sql("COUNT(*) FILTER (WHERE answers.correct)")
                           )
    specialties = Specialty.where(id: counts.map(&:first)).index_by(&:id)

    counts.map { |id, asked, correct| [specialties[id], correct, asked] }
          .sort_by { |specialty, _correct, _asked| specialty.position }
  end

  # What analytics reports about a sitting, at the start and again at the end.
  def usage_properties
    {
      mode: mode, question_count: question_count, feedback_timing: feedback_timing, timed: !time_limit_seconds.nil?,
      enarm_mode: enarm_mode
    }
  end

  private

  def report_finished
    Analytics.capture(
      user, "exam_finished",
      usage_properties.merge(
        answered: answers.count, score: score.to_f, minutes: elapsed_seconds / 60, ran_out_of_time: time_up?
      )
    )
  end

  def reschedule_reviews
    Reviews::CaseScheduler.call(user, exam_questions.reorder(nil).distinct.pluck(:clinical_case_id))
  end
end
