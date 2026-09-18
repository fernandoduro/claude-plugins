# No Meat Proxy

Source: https://nomeatproxy.com/ — by John Mikael Lindbakk (source on GitHub). Inlined here so the skill never needs to fetch it. This is the site's first half; see the note at the end.

> AI is a tool. You shouldn't be.

## Don't paste AI responses to people

**Don't**

> **Jim:** Hey, how do the feature toggles work? Can we specify per user?
>
> **Kevin:** The feature flag system here is a config based custom implementation. Definition: a FeatureToggles class — a @ConfigurationProperties data class with boolean fields (e.g. enableNewCheckoutFlow, useOptimizedSearchIndex), registered via @EnableConfigurationProperties in a FeatureConfig class. Usage pattern: inject FeatureToggles and branch on the property, e.g. if (!featureToggles.enableNewCheckoutFlow) throw a ForbiddenException. Some flags gate an early return/exception, others switch between implementations entirely. Configuration is plain YAML under app.feature-toggles.*, with per-profile overrides, and since it's standard @ConfigurationProperties, it's also overridable via env vars. This means that toggling a feature per user is not possible given today's implementation.

**Do**

> **Jim:** Hey, how do the feature toggles work? Can we specify per user?
>
> **Kevin:** I'm afraid not. It's a hardcoded on and off switch.

By simply regurgitating what an AI gave, you made everything much harder on the one who asked the question. AI-generated answers tend to be long-winded, over-complicated and often include details that weren't requested. They asked you because they trusted your judgment. By simply forwarding AI output, you're just acting as a middleman. You're just a meat proxy.

If all you do is relay messages between people and an AI, what value do you bring?

By replying with AI answers, you're:

- making it harder for everyone else.
- highlighting your own replaceability.
- not actually being helpful.
- looking unprofessional.
- making people trust you less.

More things to avoid:

- Don't "contribute" to discussion by pasting wall-of-text AI results.
- Don't ask questions like "Hey, so I have this problem: <Big ass AI-generated block of text>".

Here is what you should try instead:

- Do read and verify AI output.
- Do formulate your own answers and questions.
- Do contribute to discussions when you have something meaningful to contribute.

Answer people like a person. Treat people like people. Don't be a meat proxy!

The site has a second half about owning AI-written work you submit. That is a different concept and deliberately not part of this skill, which is only about the first: the person relaying your output must be able to say it themselves.

## Why this matters (links on the site)

- Don't Be a Meat Proxy (original inspiration)
- The Effort Economy of Slop
- If You are Asking for Human Attention, Demonstrate Human Effort
- Meat-based llm proxies

Inspired by: Don't ask to ask, just ask · No Hello
