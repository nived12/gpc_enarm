# A clinical vignette and the two or three questions asked about it.
#
# The convocatoria is explicit that every ENARM item is a case with 2–3 questions, one
# correct option and three distractors, so the case is the unit throughout — exams select
# whole cases, never orphan questions.
class ClinicalCase < ApplicationRecord
  include Exportable

  belongs_to :topic, optional: true
  belongs_to :specialty, optional: true
  # Where the case happens: one of the three cross-cutting contexts the convocatoria frames
  # every case in. `specialty` is what the case is about. Nil is unknown, never "none".
  belongs_to :setting, class_name: "Specialty", optional: true
  belongs_to :guideline, optional: true
  belongs_to :generation_run, optional: true
  belongs_to :clinical_image, optional: true

  has_many :questions, -> { originals.order(:position) }, dependent: :destroy, inverse_of: :clinical_case
  has_many :question_reports, through: :questions

  # CIFRHS's own vocabulary, rendered Baja / Media / Alta. Never a competitor's invented
  # Interno / Residente / Adscrito: difficulty is what actually breaks ties on the real
  # exam, and the simulator should teach the student the axis they will be ranked on.
  enum :difficulty,
    { low: "low", medium: "medium", high: "high" },
    prefix: :difficulty

  enum :status,
    { draft: "draft", published: "published", flagged: "flagged", retired: "retired" },
    prefix: :status

  enum :source,
    { gpc_generated: "gpc_generated", authored: "authored", imported: "imported" },
    prefix: :source

  enum :verification_verdict,
    { supported: "supported", unsupported: "unsupported", ambiguous: "ambiguous", flawed: "flawed" },
    prefix: :verdict

  validates :stem, presence: true
  validates :locale, presence: true

  validate :published_only_when_supported
  validate :setting_is_cross_cutting

  # Withdrawn cases stay back whatever the verifier said, because both are a person's
  # decision and outrank a model's agreement: `flagged` is staff holding a case until it
  # is decided, `retired` is that decision. A student's report never flags a case — one
  # student could otherwise pull an item from everyone's bank — it only queues it.
  WITHDRAWN = %w[flagged retired].freeze

  scope :publishable, -> { verdict_supported.where.not(status: WITHDRAWN) }
  # Cases a second opinion passed, or found only item-writing defects in, before `time`:
  # what questions:recheck reads again after the verifier learns to see something new.
  # Passing the same time twice continues rather than repeats, since a recheck moves
  # verified_at past it.
  scope :recheckable_before, lambda { |time|
    where(verification_verdict: %w[supported flawed]).where(verified_at: ...time).where.not(status: "retired")
  }

  # The cases an area holds: those about it, and those that happen in it. The owner's
  # decision of 2026-09-23 — a case of pneumonia seen in urgencias counts for Medicina
  # Interna and for Urgencias. An OR, so a case about Urgencias that is also set there is
  # still one case, and picking several areas never returns a case twice.
  scope :in_area, ->(specialties) { where(specialty: specialties).or(where(setting: specialties)) }

  # One row per case and area it belongs to, `areas.area_id` naming the area. The UNION
  # drops the second copy when subject and setting are the same specialty, which is what
  # keeps that case from counting twice in its own area.
  AREAS_JOIN = <<~SQL.squish.freeze
    CROSS JOIN LATERAL (
      SELECT area_id FROM (SELECT clinical_cases.specialty_id UNION SELECT clinical_cases.setting_id) AS pair(area_id)
      WHERE area_id IS NOT NULL
    ) AS areas
  SQL

  scope :by_area, -> { joins(AREAS_JOIN) }

  # Specialty id => cases in that area. Areas overlap, so these do not add up to the
  # number of cases; count the relation itself for that.
  def self.count_by_area
    by_area.group("areas.area_id").count
  end

  scope :with_open_reports, -> { where(id: QuestionReport.status_open.joins(:question).select(:clinical_case_id)) }

  # What still needs a person: withdrawn pending a decision, not supported by the second
  # opinion (or not read by it yet), or reported by a student. Retired is a decision
  # already taken, so it leaves the queue.
  scope :in_review_queue, lambda {
    where.not(status: "retired").and(
      status_flagged.or(where(verification_verdict: [nil, "unsupported", "ambiguous", "flawed"])).or(with_open_reports)
    )
  }

  # A case may only go live once a second model family has agreed its correct answer is
  # actually supported by the quote it cites. Unverified and unsupported both stay back:
  # silence from the verifier is not assent.
  def publishable?
    verdict_supported? && WITHDRAWN.exclude?(status)
  end

  # The status a new second opinion leaves the case in. A live case the verdict no longer
  # supports comes off the bank at once; putting one on is Questions::Publisher's job
  # alone, so a supported draft stays a draft here. The verifier and the importer's
  # verdict sync both go through this.
  def status_after_verdict(verdict)
    status_published? && verdict != "supported" ? "draft" : status
  end

  private

  def published_only_when_supported
    errors.add(:status, :not_supported) if status_published? && !verdict_supported?
  end

  # A troncal is what a case is about, never where it happens.
  def setting_is_cross_cutting
    errors.add(:setting, :not_cross_cutting) if setting && !setting.kind_cross_cutting?
  end
end
