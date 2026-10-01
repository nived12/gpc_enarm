# Draws an exam from the published bank: whole clinical cases, never orphan questions,
# because every ENARM item is a case with its two or three questions.
#
# Specialties are interleaved unless the student opts out. Blocked practice — all of
# Cardiología, then all of Nefrología — feels better and trains the wrong skill: on exam
# day nothing announces which specialty the next case belongs to, and telling them apart
# is part of what is being examined.
module Exams
  class Builder < ApplicationService
    CUSTOM_COUNTS = (5..100)
    DEFAULT_CUSTOM_COUNT = 20
    CUSTOM_CHOICES = [10, 20, 40, 60, 100].freeze

    def initialize(user:, mode:, filters: {}, settings: {}, random: Random.new)
      super()
      @user = user
      @mode = mode.to_s
      @raw_filters = filters.to_h.with_indifferent_access
      @settings = settings.to_h.with_indifferent_access
      @random = random
    end

    def call
      return failure(I18n.t("exams.builder.unknown_mode")) unless Exam.modes.key?(mode)
      return daily_limit_reached unless access[:allowed]

      picked = pick
      return failure(I18n.t("exams.builder.nothing_matches")) if picked.empty?

      success(exam: create_exam(picked))
    end

    def context_for_logging
      { user_id: user.id, mode: mode, filters: filters }
    end

    private

    attr_reader :user, :mode, :raw_filters, :settings, :random

    # Refused before drawing anything, so a free student who has used today's allowance
    # is not handed an exam whose first answer would be turned away.
    def access
      @access ||= user.subscription_access_result
    end

    def daily_limit_reached
      errors.add(:base, :daily_limit_reached, message: access[:message])
      failure
    end

    # Each mode has defaults; the student may change either. A missing or unknown value
    # falls back to the default rather than failing the exam.
    def feedback_timing
      chosen = settings[:feedback_timing]
      Exam.feedback_timings.key?(chosen) ? chosen : Exam.default_feedback_timing(mode)
    end

    # "" is the student choosing no clock at all, which is different from not saying.
    def seconds_per_question
      return Exam.default_seconds_per_question(mode) unless settings.key?(:seconds_per_question)

      settings[:seconds_per_question].to_i.then { |pace| pace if Exam::PACES.include?(pace) }
    end

    # The presets are fixed exams; only "Arma tu examen" reads the student's choices.
    def filters
      @filters ||= if mode == "custom"
        {
          "question_count" => raw_filters[:question_count].presence&.to_i&.clamp(CUSTOM_COUNTS) || DEFAULT_CUSTOM_COUNT,
          "specialty_ids" => Array(raw_filters[:specialty_ids]).compact_blank.map(&:to_i),
          "topic_ids" => Array(raw_filters[:topic_ids]).compact_blank.map(&:to_i),
          "also_setting_ids" => Array(raw_filters[:also_setting_ids]).compact_blank.map(&:to_i),
          "difficulties" => Array(raw_filters[:difficulties]) & ClinicalCase.difficulties.keys,
          "unseen_only" => boolean(:unseen_only, default: false),
          "previously_wrong_only" => boolean(:previously_wrong_only, default: false),
          "interleave" => boolean(:interleave, default: true)
        }.compact_blank.merge("interleave" => boolean(:interleave, default: true))
      else
        { "interleave" => true }
      end
    end

    def boolean(key, default:)
      raw_filters.key?(key) ? ActiveModel::Type::Boolean.new.cast(raw_filters[key]) : default
    end

    def target
      filters["question_count"] || Exam::QUESTION_COUNTS.fetch(mode)
    end

    # Exactly the number asked for, as the real exam's 280 are, from whole cases. How
    # many cases of each size to take is settled first — the mix that adds up exactly
    # and stays closest to the bank's own share of two- and three-question cases — and
    # the interleaved draw is then read in order until each size has its count. A bank
    # smaller than the target gives what it has; one that cannot add up exactly runs
    # over by as little as a case allows, as the draw always did.
    def pick
      rows = own_topics_first(ordered(candidates))
      chosen = by_difficulty(rows) || take(rows, target)
      filters["interleave"] ? chosen : blocked(chosen)
    end

    def take(rows, wanted)
      quotas = exact_quotas(rows.map(&:last).tally, wanted)
      quotas ? rows.select { |row| (quotas[row.last] -= 1) >= 0 } : overshoot(rows, wanted)
    end

    # A rehearsal of the real exam takes its difficulty mix too — the 2026 answer sheet
    # was 70 low, 140 medium and 70 high of 280 — drawn level by level from the already
    # interleaved order, so the levels stay mixed through the exam. A bank short of any
    # level falls back to the plain draw rather than handing over a short exam.
    def by_difficulty(rows)
      return unless Exam::EXAM_LENGTH_MODES.include?(mode)

      wanted = difficulty_targets
      levels = rows.group_by { |row| row[2] }
      return if wanted.any? { |level, count| levels.fetch(level, []).sum(&:last) < count }

      kept = wanted.flat_map { |level, count| take(levels[level], count) }.to_set
      rows.select { |row| kept.include?(row) }
    end

    def difficulty_targets
      low, high = Exam::DIFFICULTY_MIX.values_at("low", "high").map { |share| (target * share).round }
      { "low" => low, "medium" => target - low - high, "high" => high }
    end

    # A study day widened by its setting still quizzes its own topics first: in a context
    # like Medicina Familiar, cases merely set there far outnumber the day's topics.
    def own_topics_first(rows)
      return rows unless filters["topic_ids"] && filters["also_setting_ids"]

      own = ClinicalCase.where(id: rows.map(&:first), topic_id: filters["topic_ids"]).pluck(:id).to_set
      rows.partition { |row| own.include?(row.first) }.flatten(1)
    end

    def exact_quotas(available, wanted)
      bank = available.sum { |size, count| size * count }
      return available.dup if bank <= wanted

      combinations(available.to_a, wanted).min_by do |quotas|
        quotas.sum { |size, count| ((size * count) - (wanted * size * available[size] / bank.to_f))**2 }
      end
    end

    # Every way of taking cases of these sizes, within what is available, to make `left`.
    def combinations(sizes, left)
      return (left.zero? ? [{}] : []) if sizes.empty?

      (size, available), *rest = sizes
      (0..[available, left / size].min).flat_map do |count|
        combinations(rest, left - (size * count)).map { |quotas| quotas.merge(size => count) }
      end
    end

    def overshoot(rows, wanted)
      total = 0
      rows.take_while { |row| (total < wanted).tap { total += row.last } }
    end

    # A specialty picked is an area: the cases about it and the cases set in it, each
    # once however many areas are picked. The deal below still interleaves by subject.
    def candidates
      cases = ClinicalCase.status_published
      cases = cases.in_area(filters["specialty_ids"]) if filters["specialty_ids"]
      cases = with_topics(cases)
      cases = cases.where(difficulty: filters["difficulties"]) if filters["difficulties"]
      cases = cases.where.not(id: seen_cases) if filters["unseen_only"]
      cases = cases.where(id: missed_cases) if filters["previously_wrong_only"]

      cases.joins(:questions).group(:id, :specialty_id, :difficulty)
           .order(:id).pluck(:id, :specialty_id, :difficulty, Arel.sql("COUNT(questions.id)"))
    end

    # `also_setting_ids` widens the topics rather than narrowing them: a study day in one
    # of the three contexts quizzes its own topics or anything set in that context, since
    # the bank files hardly a case under a context's topics.
    def with_topics(cases)
      topic_ids, setting_ids = filters.values_at("topic_ids", "also_setting_ids")
      return cases unless topic_ids || setting_ids

      cases.where(topic_id: Array(topic_ids)).or(cases.where(setting_id: Array(setting_ids)))
    end

    def seen_cases
      ExamQuestion.answered_by(user).select(:clinical_case_id)
    end

    # A case answered wrong at least once. A question left blank is not counted: the
    # case may never have been read, and one never seen cannot be "previously wrong".
    def missed_cases
      ExamQuestion.answered_by(user).where(answers: { correct: false }).select(:clinical_case_id)
    end

    # Shuffled, then dealt one specialty at a time, so the draw is interleaved and a
    # short quiz still touches several specialties.
    def ordered(rows)
      queues = rows.shuffle(random: random).group_by { |_id, specialty_id, _difficulty, _count| specialty_id }.values
      dealt = []
      dealt.concat(queues.filter_map(&:shift)) until queues.all?(&:empty?)
      dealt
    end

    def blocked(rows)
      positions = Specialty.pluck(:id, :position).to_h
      rows.each_with_index.sort_by { |(_id, specialty_id, _difficulty, _count), index| [positions.fetch(specialty_id, Float::INFINITY), index] }
          .map(&:first)
    end

    def create_exam(picked)
      case_ids = picked.map(&:first)
      questions = Question.where(clinical_case_id: case_ids).order(:position).group_by(&:clinical_case_id)
      sequence = case_ids.flat_map { |case_id| questions.fetch(case_id) }

      pace = seconds_per_question
      Exam.transaction do
        exam = user.exams.create!(
          mode: mode, filters: filters, question_count: sequence.size,
          feedback_timing: feedback_timing, seconds_per_question: pace,
          time_limit_seconds: pace && (pace * sequence.size),
          started_at: Time.current, running_since: Time.current
        )
        sequence.each.with_index(1) do |question, position|
          exam.exam_questions.create!(
            question: question, clinical_case_id: question.clinical_case_id,
            position: position
          )
        end
        exam
      end
    end
  end
end
