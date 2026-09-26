# The order a run takes the corpus in: a list of [guideline, statements] windows, one per
# generation call, made of statements no question cites yet and that ask a general
# physician's decision (Recommendation#decision_kind).
#
# Breadth first: every guideline's first window before any guideline's second, so a run
# stopped early — by the cap, a crash, or on purpose — has touched the whole syllabus
# thinly rather than a few topics deeply. Within a pass, current guidelines first, newest
# first, since the plan prefers them.
#
# `by_specialty` deals the windows out one specialty at a time instead. Newest-first alone
# is not balanced: the pilot's first 99 windows would have given Cirugía General 4 calls
# and Salud Pública none, because Medicina Interna owns half the corpus. A guideline's
# specialty is the one its main topic is filed under — the same one its cases get.
module Questions
  class WindowPlan
    ORDERS = %w[newest by_specialty].freeze

    def initialize(guidelines, order: "newest", specialty: nil)
      @guidelines = guidelines
      @order = ORDERS.include?(order.to_s) ? order.to_s : "newest"
      @specialty = specialty
    end

    def windows
      @windows ||= begin
        queue = interleave(per_guideline)
        queue = queue.select { |guideline, _| specialty_of(guideline) == specialty.id } if specialty
        order == "by_specialty" ? interleave(queue.group_by { |guideline, _| specialty_of(guideline) }.values) : queue
      end
    end

    private

    attr_reader :guidelines, :order, :specialty

    # One list per guideline of its [guideline, window] pairs.
    def per_guideline
      by_guideline = uncited.group_by(&:source_guideline_id)
      ordered = guidelines.where(id: by_guideline.keys).order(Arel.sql("year DESC NULLS LAST"), :catalog_key)
      ordered.map do |guideline|
        by_guideline[guideline.id].each_slice(CaseGenerator::RECOMMENDATIONS_PER_CALL).map { |window| [guideline, window] }
      end
    end

    # Round robin: the first of every list, then the second of every list, and so on.
    def interleave(lists)
      deepest = lists.map(&:size).max.to_i
      (0...deepest).flat_map { |index| lists.filter_map { |list| list[index] } }
    end

    def specialty_of(guideline)
      @specialties ||= {}
      @specialties.fetch(guideline.id) { @specialties[guideline.id] = guideline.main_topic&.branch&.specialty_id }
    end

    def uncited
      Recommendation.actionable.decision_general_practice
                    .where(guideline_sections: { guideline_id: guidelines.select(:id) })
                    .where.not(id: Question.where.not(recommendation_id: nil).select(:recommendation_id))
                    .select("recommendations.*, guideline_sections.guideline_id AS source_guideline_id")
                    .order(:id)
    end
  end
end
