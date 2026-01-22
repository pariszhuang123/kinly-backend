-- Seed preference report templates (default v1, en).
-- Requires preference_report_templates table per contract.
insert into public.preference_report_templates (
  template_key,
  locale,
  body
) values (
  'personal_preferences_v1',
  'en',
  '{
    "template_key": "personal_preferences_v1",
    "locale": "en",
    "summary": {
      "title": "Personal preferences",
      "subtitle": "This helps housemates understand comfort styles. Not rules."
    },
    "preferences": {
      "environment_noise_tolerance": [
        { "value_key": "low", "title": "Low", "text": "I''m most comfortable when shared spaces are mostly quiet." },
        { "value_key": "medium", "title": "Medium", "text": "Some background noise is fine, especially at reasonable hours." },
        { "value_key": "high", "title": "High", "text": "I''m generally okay with lively noise in shared spaces." }
      ],
      "environment_light_preference": [
        { "value_key": "dim", "title": "Dim", "text": "I prefer softer lighting in shared spaces." },
        { "value_key": "balanced", "title": "Balanced", "text": "I''m comfortable with a mix of natural and indoor light." },
        { "value_key": "bright", "title": "Bright", "text": "I feel best with brighter lighting in shared areas." }
      ],
      "environment_scent_sensitivity": [
        { "value_key": "sensitive", "title": "Sensitive", "text": "Strong scents can bother me, so I prefer mild/no fragrance." },
        { "value_key": "neutral", "title": "Neutral", "text": "I''m okay with light scents in moderation." },
        { "value_key": "tolerant", "title": "Tolerant", "text": "Scent usually doesn''t affect me much." }
      ],
      "schedule_quiet_hours_preference": [
        { "value_key": "early_evening", "title": "Early evening", "text": "I prefer things to wind down earlier in the evening." },
        { "value_key": "late_evening_or_night", "title": "Late evening", "text": "Later evenings are fine for me if people are mindful." },
        { "value_key": "none", "title": "No preference", "text": "I don''t have a strong quiet-hours preference." }
      ],
      "schedule_sleep_timing": [
        { "value_key": "early", "title": "Early", "text": "I usually sleep and wake earlier." },
        { "value_key": "standard", "title": "Standard", "text": "My sleep timing is fairly typical." },
        { "value_key": "late", "title": "Late", "text": "I tend to sleep and wake later." }
      ],
      "communication_channel": [
        { "value_key": "text", "title": "Text", "text": "I prefer messages for quick coordination." },
        { "value_key": "call", "title": "Call", "text": "I prefer a quick call when something matters." },
        { "value_key": "in_person", "title": "In person", "text": "I prefer talking face-to-face when possible." }
      ],
      "communication_directness": [
        { "value_key": "gentle", "title": "Gentle", "text": "I prefer softer phrasing and good timing." },
        { "value_key": "balanced", "title": "Balanced", "text": "I''m okay with a mix of directness and tact." },
        { "value_key": "direct", "title": "Direct", "text": "I''m most comfortable being straightforward." }
      ],
      "cleanliness_shared_space_tolerance": [
        { "value_key": "low", "title": "Low", "text": "I prefer shared areas to stay consistently tidy." },
        { "value_key": "medium", "title": "Medium", "text": "A bit of clutter happens, but resets are important." },
        { "value_key": "high", "title": "High", "text": "I''m generally okay with some clutter in shared spaces." }
      ],
      "privacy_room_entry": [
        { "value_key": "always_ask", "title": "Always ask", "text": "Please ask/knock before entering my room." },
        { "value_key": "usually_ask", "title": "Usually ask", "text": "A knock is great; urgent things can be flexible." },
        { "value_key": "open_door", "title": "Open door", "text": "I''m generally okay with casual entry if respectful." }
      ],
      "privacy_notifications": [
        { "value_key": "none", "title": "None", "text": "I prefer not to receive messages after quiet hours." },
        { "value_key": "limited", "title": "Limited", "text": "Only important messages after quiet hours." },
        { "value_key": "ok", "title": "Ok", "text": "I''m generally okay with late messages." }
      ],
      "social_hosting_frequency": [
        { "value_key": "rare", "title": "Rare", "text": "I feel best with guests only now and then." },
        { "value_key": "sometimes", "title": "Sometimes", "text": "Sometimes is okay with a heads-up." },
        { "value_key": "often", "title": "Often", "text": "I''m comfortable with frequent guests." }
      ],
      "social_togetherness": [
        { "value_key": "mostly_solo", "title": "Mostly solo", "text": "I recharge best with more solo time at home." },
        { "value_key": "balanced", "title": "Balanced", "text": "I like a mix of solo time and shared moments." },
        { "value_key": "mostly_together", "title": "Mostly together", "text": "I enjoy a more social, shared home." }
      ],
      "routine_planning_style": [
        { "value_key": "planner", "title": "Planner", "text": "I like plans and clear expectations." },
        { "value_key": "mixed", "title": "Mixed", "text": "Some planning helps, but I stay flexible." },
        { "value_key": "spontaneous", "title": "Spontaneous", "text": "I prefer keeping it open and adapting." }
      ],
      "conflict_resolution_style": [
        { "value_key": "cool_off", "title": "Pause", "text": "A little space first helps me reset." },
        { "value_key": "talk_soon", "title": "Talk soon", "text": "Talking it through soon helps me feel okay." },
        { "value_key": "mediate", "title": "Gentle check-in", "text": "A kind check-in at the right time helps." }
      ]
    },
    "sections": [
      { "section_key": "environment", "title": "Environment", "text": "How you prefer the shared space to feel." },
      { "section_key": "schedule", "title": "Schedule", "text": "Timing preferences that affect comfort." },
      { "section_key": "communication", "title": "Communication", "text": "How you like to coordinate and give feedback." },
      { "section_key": "cleanliness", "title": "Cleanliness", "text": "What \"tidy enough\" means to you." },
      { "section_key": "privacy", "title": "Privacy", "text": "Boundaries that help you feel at ease." },
      { "section_key": "social", "title": "Social", "text": "Your comfort with guests and togetherness." },
      { "section_key": "routine", "title": "Routine", "text": "Planning vs spontaneity." },
      { "section_key": "conflict", "title": "Repair", "text": "What helps after small tension." }
    ]
  }'::jsonb
);
