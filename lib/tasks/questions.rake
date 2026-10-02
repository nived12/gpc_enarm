namespace :questions do
  # Generation draws only on screened material, so on an unscreened corpus it would run
  # on part of it and report the rest as used up.
  unscreened = lambda do
    pending = Guideline.screening_pending.count
    "#{pending} guías sin revisar para el ENARM. Corre antes rake questions:screen[#{pending}]" if pending.positive?
  end

  desc "Generate clinical cases: rake questions:generate[calls,budget_usd,source,order,specialty] " \
       "(source: live_site|web_archive; order: newest|by_specialty; specialty: a slug, to top one up)"
  task :generate, %i[calls budget source order specialty] => :environment do |_task, args|
    calls = (args[:calls] || 10).to_i
    budget = args[:budget].presence&.to_f
    order = args[:order].presence || "newest"
    abort("Orden desconocido: #{order}. Usa #{Questions::WindowPlan::ORDERS.join(" o ")}") \
      unless Questions::WindowPlan::ORDERS.include?(order)
    specialty = Specialty.find_by(slug: args[:specialty]) if args[:specialty].present?
    abort("No existe la especialidad #{args[:specialty]}") if args[:specialty].present? && specialty.nil?
    provider = Llm::Provider.for(:generator)
    abort("Falta la clave del generador. Revisa .env") unless provider.configured?
    unscreened.call&.then { |message| abort(message) }

    guidelines = Guideline.generatable
    guidelines = guidelines.where(source: args[:source]) if args[:source].present?

    run = GenerationRun.create!(
      purpose: "generation", provider: provider.name,
      model: provider.model, started_at: Time.current
    )

    result = Questions::GenerationRunner.call(
      run: run, calls: calls, budget_usd: budget, guidelines: guidelines, order: order, specialty: specialty,
      on_progress: ->(line) { puts line }
    )
    run.update!(status: result.success? ? "completed" : "failed", finished_at: Time.current)
    abort(result.errors.full_messages.to_sentence) if result.failure?

    run.reload
    puts "\ncasos=#{run.cases_created} descartadas=#{run.rejections} tokens=#{run.total_tokens} " \
         "costo=$#{format("%.4f", run.cost_usd)}#{" (tope alcanzado)" if result.payload[:stopped_at_budget]}"
    puts "Detenida tras #{Questions::GenerationRunner::FAILURES_IN_A_ROW} fallas seguidas." \
         if result.payload[:stopped_after_failures]
  end

  desc "Write the generated bank to one portable file: rake questions:export[path]"
  task :export, [:path] => :environment do |_task, args|
    result = Questions::Exporter.call(args[:path] || "tmp/question-bank.jsonl.gz")
    abort(result.errors.full_messages.to_sentence) unless result.success?

    payload = result.payload
    puts "#{payload[:path]} · #{payload[:cases]} casos · #{payload[:questions]} preguntas · " \
         "#{payload[:runs]} corridas · #{ActiveSupport::NumberHelper.number_to_human_size(payload[:bytes])}"
  end

  import_bank = lambda do |path, only_new:|
    result = Questions::Importer.call(path || "tmp/question-bank.jsonl.gz", only_new: only_new)
    counts = result.payload
    if counts
      puts "casos importados: #{counts[:cases_created] + counts[:cases_updated]}, " \
           "omitidos por existir: #{counts[:cases_skipped]}, rechazados: #{counts[:cases_refused]}"
      puts counts.map { |key, value| "#{key}: #{value}" }.join(", ")
    end
    abort(result.errors.full_messages.to_sentence) unless result.success?
  end

  desc "Load a file written by questions:export into this database, overwriting the cases it already has [path]"
  task :import, [:path] => :environment do |_task, args|
    import_bank.call(args[:path], only_new: false)
  end

  # Once review happens in production, a case there has a status and edits the file
  # knows nothing about; only the cases production lacks may come in. The second opinion's
  # verdicts still move on to the cases it has, and may only take one off the bank.
  desc "Load the cases this database does not have yet, and newer verdicts on the ones it has [path]"
  task :import_new, [:path] => :environment do |_task, args|
    import_bank.call(args[:path], only_new: true)
  end

  desc "File every case under its guideline's current main topic, after taxonomy:seed and gpc:link"
  task refile: :environment do
    puts "casos reubicados: #{Questions::Refiler.call.payload[:moved]}"
  end

  desc "Read the setting of every case that has none from its vignette, without a model: " \
       "rake questions:classify_settings[dry_run] (any value for dry_run only counts)"
  task :classify_settings, [:dry_run] => :environment do |_task, args|
    dry_run = args[:dry_run].present?
    result = Questions::SettingClassifier.call(dry_run: dry_run).payload

    puts "#{"Simulación: nada se guardó. " if dry_run}Contextos asignados:"
    Specialty.kind_cross_cutting.in_reading_order.each do |setting|
      puts "  #{setting.name}: #{result[:classified].fetch(setting.slug, 0)}"
    end
    puts "Sin contexto reconocible: #{result[:unclassified].size}"
    puts "  ids: #{result[:unclassified].join(", ")}" if result[:unclassified].any?
  end

  desc "Rate guidelines for the ENARM and label their statements, before generating from them: " \
       "rake questions:screen[count] (count: guidelines)"
  task :screen, [:count] => :environment do |_task, args|
    provider = Llm::Provider.for(:verifier)
    abort("Falta la clave del verificador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "screening", provider: provider.name, model: provider.model, started_at: Time.current
    )
    failures_in_a_row = 0
    Guideline.screening_pending.order(
      Arel.sql("screened_at ASC NULLS FIRST"),
      :catalog_key
    ).limit((args[:count] || 10).to_i).each do |guideline|
      result = Questions::SourceScreener.call(guideline, run: run)
      labels = result.payload[:labelled].map { |kind, n| "#{kind}=#{n}" }.join(" ")
      puts "#{guideline.catalog_key}: #{guideline.enarm_relevance || "sin calificar"} #{labels}" \
           "#{" — #{result.errors.full_messages.to_sentence}" if result.failure?}"
      failures_in_a_row = result.success? ? 0 : failures_in_a_row + 1
      break if failures_in_a_row == 3
    end

    run.update!(status: failures_in_a_row == 3 ? "failed" : "completed", finished_at: Time.current)
    puts "\nPendientes: #{Guideline.screening_pending.count} guías. llamadas=#{run.calls} " \
         "tokens=#{run.total_tokens} costo=$#{format("%.4f", run.cost_usd)}"
    puts "Detenida tras 3 fallas seguidas; no se reintentó." if run.status_failed?
  end

  desc "Have a second model family judge unverified cases: rake questions:verify[count]"
  task :verify, [:count] => :environment do |_task, args|
    count = (args[:count] || 10).to_i
    provider = Llm::Provider.for(:verifier)
    abort("Falta la clave del verificador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "verification", provider: provider.name,
      model: provider.model, started_at: Time.current
    )

    tally = Hash.new(0)
    ClinicalCase.where(verification_verdict: nil).order(:id).limit(count).each do |kase|
      result = Questions::Verifier.call(kase, run: run)
      state = result.success? ? result.payload[:verdict] : result.errors.full_messages.first
      tally[state] += 1
      rationales = result.payload[:rationales] if result.success?
      puts "caso #{kase.id}: #{state}#{" razones #{rationales.to_json}" if rationales}"
    end

    run.update!(status: "completed", finished_at: Time.current)
    puts "\n#{tally.map { |verdict, n| "#{verdict}=#{n}" }.join(" ")} tokens=#{run.total_tokens}"
  end

  desc "Judge again the supported or flawed cases verified before a time, then publish: " \
       "rake questions:recheck[count,2026-09-26T02:00:00Z]"
  task :recheck, %i[count before] => :environment do |_task, args|
    abort("Uso: rake questions:recheck[count,before]") if args[:before].blank?
    before = Time.zone.parse(args[:before]) || abort("No entiendo la fecha #{args[:before]}")
    provider = Llm::Provider.for(:verifier)
    abort("Falta la clave del verificador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "verification", provider: provider.name, model: provider.model,
      started_at: Time.current, notes: "recheck"
    )
    tally = Hash.new(0)
    ClinicalCase.recheckable_before(before).order(:verified_at, :id).limit((args[:count] || 10).to_i).each do |kase|
      result = Questions::Verifier.call(kase, run: run)
      state = result.success? ? result.payload[:verdict] : result.errors.full_messages.first
      tally[state] += 1
      puts "caso #{kase.id}: #{state}"
    end

    run.update!(status: "completed", finished_at: Time.current)
    payload = Questions::Publisher.call.payload
    puts "\n#{tally.map { |verdict, n| "#{verdict}=#{n}" }.join(" ")} costo=$#{format("%.4f", run.cost_usd)} " \
         "en_el_banco=#{payload[:live]}"
  end

  desc "Publish every verifier-supported case nobody has withdrawn, and pull back any that no longer qualify"
  task publish: :environment do
    payload = Questions::Publisher.call.payload
    puts "publicados=#{payload[:published]} retirados_del_banco=#{payload[:withdrawn]} en_el_banco=#{payload[:live]}"
  end

  desc "Write why each distractor is wrong, for cases that lack it: rake questions:write_rationales[count]"
  task :write_rationales, [:count] => :environment do |_task, args|
    count = (args[:count] || 10).to_i
    provider = Llm::Provider.for(:generator)
    abort("Falta la clave del generador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "rationales", provider: provider.name, model: provider.model, started_at: Time.current
    )

    missing = AnswerOption.where(correct: false, rationale: nil).joins(:question).select("questions.clinical_case_id")
    cases = ClinicalCase.where(id: missing).where.not(status: "retired").order(:id).limit(count)
    tally = Hash.new(0)
    cases.each do |kase|
      result = Questions::RationaleWriter.call(kase, run: run)
      state = result.success? ? "#{result.payload[:written]} razones" : result.errors.full_messages.first
      tally[result.success? ? :ok : :failed] += 1
      puts "caso #{kase.id}: #{state}"
    end

    run.update!(status: "completed", finished_at: Time.current)
    puts "\ncasos=#{tally[:ok]} fallidos=#{tally[:failed]} tokens=#{run.total_tokens} costo=$#{format(
      "%.4f",
      run.cost_usd
    )}"
  end

  desc "Judge the unjudged distractor rationales of verifier-supported cases: " \
       "rake questions:verify_rationales[count]"
  task :verify_rationales, [:count] => :environment do |_task, args|
    count = (args[:count] || 10).to_i
    provider = Llm::Provider.for(:verifier)
    abort("Falta la clave del verificador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "verification", provider: provider.name, model: provider.model, started_at: Time.current,
      notes: "rationales"
    )

    unjudged = AnswerOption.rationale_unjudged.joins(:question).select("questions.clinical_case_id")
    cases = ClinicalCase.where(id: unjudged).verdict_supported.where.not(status: "retired")
    tally = Hash.new(0)
    cases.order(:id).limit(count).each do |kase|
      result = Questions::RationaleVerifier.call(kase, run: run)
      if result.success?
        result.payload.each { |verdict, n| tally[verdict] += n }
        puts "caso #{kase.id}: #{result.payload.map { |verdict, n| "#{verdict}=#{n}" }.join(" ")}"
      else
        tally[:failed_cases] += 1
        puts "caso #{kase.id}: #{result.errors.full_messages.first}"
      end
    end

    run.update!(status: "completed", finished_at: Time.current)
    puts "\n#{tally.map { |verdict, n| "#{verdict}=#{n}" }.join(" ")} tokens=#{run.total_tokens} " \
         "costo=$#{format("%.4f", run.cost_usd)}"
  end

  desc "Rewrite the rationales the verifier rejected, then run verify_rationales: " \
       "rake questions:rewrite_rationales[count]"
  task :rewrite_rationales, [:count] => :environment do |_task, args|
    count = (args[:count] || 10).to_i
    provider = Llm::Provider.for(:generator)
    abort("Falta la clave del generador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "rationales", provider: provider.name, model: provider.model, started_at: Time.current,
      notes: "rewrite"
    )

    rejected = AnswerOption.rationale_rejected.joins(:question).select("questions.clinical_case_id")
    tally = Hash.new(0)
    ClinicalCase.where(id: rejected).where.not(status: "retired").order(:id).limit(count).each do |kase|
      result = Questions::RationaleWriter.call(kase, run: run, rewrite: true)
      state = result.success? ? "#{result.payload[:written]} razones" : result.errors.full_messages.first
      tally[result.success? ? :ok : :failed] += 1
      puts "caso #{kase.id}: #{state}"
    end

    run.update!(status: "completed", finished_at: Time.current)
    puts "\ncasos=#{tally[:ok]} fallidos=#{tally[:failed]} tokens=#{run.total_tokens} " \
         "costo=$#{format("%.4f", run.cost_usd)}"
    puts "Las razones reescritas quedan sin revisar: corre questions:verify_rationales."
  end

  desc "Write Modo ENARM's best-available-answer version of published questions (paid) " \
       "[count]"
  task :best_available, [:count] => :environment do |_task, args|
    count = (args[:count] || 10).to_i
    provider = Llm::Provider.for(:generator)
    abort("Falta la clave del generador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "best_available", provider: provider.name, model: provider.model, started_at: Time.current
    )
    pending = Question.originals.joins(:clinical_case).merge(ClinicalCase.status_published)
                      .where.not(recommendation_id: nil).where.missing(:best_available_variant)

    tally = Hash.new(0)
    pending.order("RANDOM()").limit(count).includes(:answer_options, :clinical_case, :recommendation).each do |question|
      result = Questions::BestAvailableWriter.call(question, run: run)
      outcome = if result.failure? then :failed
      elsif result.payload[:variant] then :written
      else :declined
      end
      tally[outcome] += 1
      puts "pregunta #{question.id}: #{outcome == :failed ? result.errors.full_messages.first : outcome}"
    end

    run.update!(status: "completed", finished_at: Time.current)
    puts "\nescritas=#{tally[:written]} sin_opcion_defendible=#{tally[:declined]} fallidas=#{tally[:failed]} " \
         "tokens=#{run.total_tokens} costo=$#{run.cost_usd.to_f.round(4)}"
  end

  desc "The whole bank, in chunks: generate, back up, verify, publish, to a dollar cap. Totals are per label, " \
       "so re-running the same command continues: rake questions:full_run[calls,budget_usd,label,chunk]"
  task :full_run, %i[calls budget label chunk] => :environment do |_task, args|
    abort("Uso: rake questions:full_run[calls,budget_usd,label,chunk]") if args[:calls].blank? || args[:budget].blank?
    missing = Llm::Provider.all.reject(&:configured?)
    abort("Faltan claves: #{missing.map(&:role).join(", ")}. Revisa .env") if missing.any?
    unscreened.call&.then { |message| abort(message) }

    result = Questions::FullRunner.call(
      calls: args[:calls].to_i, budget_usd: args[:budget].to_f, label: args[:label].presence || "full",
      chunk: (args[:chunk].presence || Questions::FullRunner::CHUNK_CALLS).to_i,
      on_progress: ->(line) { puts line }
    )
    abort(result.errors.full_messages.to_sentence) if result.failure?

    summary = result.payload
    puts "\nDetenida por: #{summary[:stopped]} · llamadas=#{summary[:calls]} casos=#{summary[:cases]} " \
         "descartadas=#{summary[:rejected]} en_el_banco=#{summary[:live]} costo=$#{summary[:cost_usd]}"
    puts "Respaldo final: #{summary[:backups].last}" if summary[:backups].any?
  end

  desc "Estimate calls, tokens, dollars and yield for a run, with no network: rake questions:estimate[calls,order]"
  task :estimate, %i[calls order] => :environment do |_task, args|
    unscreened.call&.then { |message| puts "Aviso: #{message}; la estimación cubre solo lo revisado." }
    result = Questions::CostEstimator.call(
      calls: args[:calls].presence&.to_i,
      order: args[:order].presence || "by_specialty"
    )
    abort(result.errors.full_messages.to_sentence) if result.failure?

    estimate = result.payload
    measured = estimate[:measured]
    number = ->(value) { ActiveSupport::NumberHelper.number_to_delimited(value) }

    puts "Corpus: #{estimate[:guidelines]} guías, #{number[estimate[:one_pass_calls]]} llamadas para una pasada " \
         "por cada enunciado sin citar. Estimación para #{number[estimate[:calls]]} llamadas."
    puts "Medido en la corrida #{measured[:reference_run]} (#{measured[:reference_calls]} llamadas): " \
         "#{measured[:cases_per_call]} casos/llamada, #{measured[:questions_per_case]} preguntas/caso, " \
         "#{(measured[:rejection_share] * 100).round(1)}% preguntas descartadas, " \
         "#{(measured[:stem_asks_question_share] * 100).round(1)}% viñetas con pregunta, " \
         "#{(measured[:published_share] * 100).round(1)}% de casos verificados publicables."
    puts "Tokens por llamada de generación: #{number[estimate[:per_call][:input]]} entrada / " \
         "#{number[estimate[:per_call][:output]]} salida (con razones de distractores)."
    per_case = estimate[:per_case]
    puts "Tokens por caso verificado: respuestas #{per_case[:answers_input]}/#{per_case[:answers_output]}, " \
         "razones #{per_case[:rationales_input]}/#{per_case[:rationales_output]} " \
         "(+#{estimate[:pending_rationale_cases]} casos ya publicados con razones sin revisar)."
    puts "\nModelo                      Generar    Verificar  Rol configurado"
    estimate[:costs].each do |row|
      puts format(
        "%-26s  $%8.2f  $%8.2f  %s", row[:model], row[:generation], row[:verification],
        row[:roles].join(", ")
      )
    end
    yielded = estimate[:yield]
    puts "\nRendimiento: #{number[yielded[:cases]]} casos, #{number[yielded[:questions]]} preguntas; " \
         "publicables #{number[yielded[:published_cases]]} casos, " \
         "#{number[yielded[:published_questions]]} preguntas. ~#{estimate[:generation_hours]} h de generación."
    estimate[:targets].each do |target, plan|
      puts "#{number[target]} preguntas publicadas: #{number[plan[:calls]]} llamadas, ~$#{plan[:cost_usd]} " \
           "con los modelos configurados"
    end
  end
end
