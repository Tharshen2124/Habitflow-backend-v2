namespace :stripe do
  desc "Record invoices Stripe already holds but no webhook ever delivered (safe to re-run)"
  task backfill_payments: :environment do
    result = BackfillStripePayments.call

    puts "Recorded:     #{result.recorded} new payment#{'s' unless result.recorded == 1}"
    puts "Already held: #{result.already_held}"
    puts "Ignored:      #{result.ignored} (draft, open or void — not settled)"

    if result.unreachable.any?
      puts "Unreachable:  #{result.unreachable.join(', ')}"
      puts "  Stripe could not be asked about these accounts. Check STRIPE_SECRET_KEY, then re-run —"
      puts "  the accounts that did work are already recorded and will be skipped."
    end

    puts
    puts "This is a catch-up, not a replacement for the webhook. For payments to record themselves,"
    puts "run:  stripe listen --forward-to localhost:3000/subscription/webhook"
  end
end
