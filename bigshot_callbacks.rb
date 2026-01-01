# bigshot_callbacks.rb
# Cluster request and contract handlers for bigshot.lic
# Loaded by bigshot when running in head/tail mode
#
# This file is loaded inside `class Cluster` block, same pattern as cluster_callbacks.rb

# Request Handlers - Respond to leader queries about status

# Status query - returns health/mana/encumbrance/etc
Cluster.on_request(:bs_status) do |_, req|
  {
    health: percenthealth,
    mana: percentmana,
    encumbrance: Char.percent_encumbrance,
    spirit: Char.spirit,
    stamina: Char.percent_stamina,
    wounded: $bigshot&.wounded? || false,
    stunned: stunned?,
    standing: standing?,
    hidden: hidden?,
    roundtime: checkrt
  }
end

# Ready to hunt query - returns readiness and reason if not ready
Cluster.on_request(:bs_ready_to_hunt) do |_, req|
  if $bigshot
    reason = $bigshot.ready_to_hunt?
    {
      ready: reason == "ready",
      reason: reason == "ready" ? nil : reason
    }
  else
    { ready: false, reason: "bigshot not initialized" }
  end
end

# Ready to rest query - returns whether should rest and reason
Cluster.on_request(:bs_ready_to_rest) do |_, req|
  if $bigshot
    reason = $bigshot.ready_to_rest?
    {
      should_rest: !!reason,
      reason: reason || nil
    }
  else
    { should_rest: false, reason: nil }
  end
end

# Contract Handlers - Bid on tasks

# Loot contract - bid based on available capacity
Contracts.on_contract(:bs_loot_item, {
  contract_open: -> req {
    return -1 unless $bigshot
    return -1 if $bigshot.NEVER_LOOT&.include?(Char.name)

    # Bid based on available capacity (higher capacity = higher bid)
    encumbered_at = $bigshot.ENCUMBERED rescue 90
    capacity = (encumbered_at - Char.percent_encumbrance) / 100.0
    capacity.clamp(0.0, 1.0)
  },
  contract_win: -> req {
    return unless $bigshot
    $looting_inactive = false
    $bigshot.loot
    $bigshot.wait_rt
    $looting_inactive = true
  }
})
