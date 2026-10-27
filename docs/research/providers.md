# LLM API providers for Z Computer

Research date: **2026-10-27**. Every fact carries its source and the date it was seen. Anything marked
**UNVERIFIED** came from a secondary source, conflicts between sources, or could not be checked against the
provider's own docs. The machine-readable catalogue that ships in the app is
`ZKit/Sources/ZProviders/Resources/providers.json` (41 providers, 160 model entries). It was generated from the
same data, so the two files agree.

## Freshness and sources

Unless a line says otherwise, "seen 2026-10-27" means the page or model list was downloaded on 2026-10-27.

| Key | Source | Seen |
| --- | --- | --- |
| [anth-models] | https://platform.claude.com/docs/en/about-claude/models/overview | 2026-10-27 |
| [anth-cu] | https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool | 2026-10-27 |
| [anth-oai] | https://platform.claude.com/docs/en/api/openai-sdk | 2026-10-27 |
| [anth-rl] | https://platform.claude.com/docs/en/api/rate-limits | 2026-10-27 |
| [oai-models] | https://developers.openai.com/api/docs/models (plus per-model pages `/api/docs/models/<id>.md`) | 2026-10-27 |
| [oai-cu] | https://developers.openai.com/api/docs/guides/tools-computer-use | 2026-10-27 |
| [oai-cu-int] | https://developers.openai.com/api/docs/guides/tools-computer-use-integration (migration table) | 2026-10-27 |
| [oai-spec] | openai/openai-openapi spec (`max_tokens` is deprecated in favour of `max_completion_tokens`) | 2026-10-27 |
| [oai-rl] | https://developers.openai.com/api/docs/guides/rate-limits | 2026-10-27 |
| [gem-models] | https://ai.google.dev/gemini-api/docs/models (plus per-model pages) | 2026-10-27 |
| [gem-pricing] | https://ai.google.dev/gemini-api/docs/pricing | 2026-10-27 |
| [gem-rl] | https://ai.google.dev/gemini-api/docs/rate-limits | 2026-10-27 |
| [gem-cu] | https://ai.google.dev/gemini-api/docs/computer-use | 2026-10-27 |
| [gem-oai] | https://ai.google.dev/gemini-api/docs/openai | 2026-10-27 |
| [gemma] | https://ai.google.dev/gemma/docs/core/gemma_on_gemini_api | 2026-10-27 |
| [groq-models] | https://console.groq.com/docs/models | 2026-10-27 |
| [groq-rl] | https://console.groq.com/docs/rate-limits | 2026-10-27 |
| [groq-vision] | https://console.groq.com/docs/vision | 2026-10-27 |
| [groq-tools] | https://console.groq.com/docs/tool-use | 2026-10-27 |
| [groq-oai] | https://console.groq.com/docs/openai | 2026-10-27 |
| [cer-models] | https://inference-docs.cerebras.ai/models/overview and public list https://api.cerebras.ai/public/v1/models | 2026-10-27 |
| [cer-rl] | https://inference-docs.cerebras.ai/support/rate-limits | 2026-10-27 |
| [or-limits] | https://openrouter.ai/docs/api/reference/limits | 2026-10-27 |
| [or-list] | https://openrouter.ai/api/v1/models (463 models, 19 free ids) | 2026-10-27 |
| [mis-models] | https://docs.mistral.ai/models/<model>.md pages (via https://docs.mistral.ai/llms.txt) | 2026-10-27 |
| [mis-free] | https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key and /admin/billing-usage/subscriptions | 2026-10-27 |
| [gh-retired] | https://docs.github.com/en/github-models/use-github-models/prototyping-with-ai-models | 2026-10-27 |
| [cf-pricing] | https://developers.cloudflare.com/workers-ai/platform/pricing/ | 2026-10-27 |
| [cf-oai] | https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/ | 2026-10-27 |
| [cf-models] | https://developers.cloudflare.com/workers-ai/models/ and per-model pages | 2026-10-27 |
| [hf-pricing] | https://huggingface.co/docs/inference-providers/pricing and router list https://router.huggingface.co/v1/models | 2026-10-27 |
| [nim-list] | https://integrate.api.nvidia.com/v1/models | 2026-10-27 |
| [nim-forum] | NVIDIA developer forum + blogs found by web search ("~40 RPM", "no credit system since 2025-09-10") | 2026-10-27 |
| [samba-rl] | https://docs.sambanova.ai/docs/en/models/rate-limits and https://api.sambanova.ai/v1/models | 2026-10-27 |
| [together] | https://docs.together.ai/docs/serverless-models and https://docs.together.ai/docs/billing | 2026-10-27 |
| [hyp] | https://www.hyperbolic.ai/docs/inference/overview and /inference/performance-limits | 2026-10-27 |
| [fw] | https://docs.fireworks.ai/getting-started/quickstart and /guides/quotas_usage/rate-limits | 2026-10-27 |
| [di] | https://docs.deepinfra.com/chat/overview, /account/rate-limits, list https://api.deepinfra.com/v1/openai/models | 2026-10-27 |
| [cohere] | https://docs.cohere.com/docs/rate-limits, /docs/compatibility-api, /docs/models | 2026-10-27 |
| [ovh] | https://help.ovhcloud.com/csm/en-public-cloud-ai-endpoints-getting-started?id=kb_article_view&sysparm_article=KB0065401 and list https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models | 2026-10-27 |
| [chutes] | https://chutes.ai/llms.txt and list https://llm.chutes.ai/v1/models | 2026-10-27 |
| [zai] | https://docs.z.ai/guides/overview/pricing, /guides/overview/quick-start, /guides/vlm/glm-5.3-flash | 2026-10-27 |
| [ali] | https://www.alibabacloud.com/help/en/model-studio/new-free-quota, /models, /compatibility-of-openai-with-dashscope | 2026-10-27 |
| [baidu] | https://ai.baidu.com/ai-doc/AISTUDIO/Mmhslv9lf and list https://aistudio.baidu.com/llm/lmapi/v3/models | 2026-10-27 |
| [kimi] | https://platform.kimi.ai/docs/api/chat (same content at platform.moonshot.ai) | 2026-10-27 |
| [kimi-limits] | https://platform.kimi.ai/docs/pricing/limits (via web search snippets; page not read directly) | 2026-10-27 |
| [deepseek] | https://api-docs.deepseek.com/ and /quick_start/pricing | 2026-10-27 |
| [xai] | https://docs.x.ai/docs/models | 2026-10-27 |
| [minimax] | https://platform.minimax.io/docs/guides/models-intro and /docs/api-reference/text-openai-api | 2026-10-27 |
| [pplx] | https://docs.perplexity.ai/getting-started/models, /getting-started/models/models/sonar, /docs/agent-api/openai-compatibility | 2026-10-27 |
| [poe] | https://creator.poe.com/docs/external-applications/openai-compatible-api | 2026-10-27 |
| [vercel] | https://vercel.com/docs/ai-gateway/pricing, /docs/ai-gateway/rate-limits, list https://ai-gateway.vercel.sh/v1/models | 2026-10-27 |
| [poll] | https://gen.pollinations.ai/docs/llm.txt and list https://gen.pollinations.ai/v1/models | 2026-10-27 |
| [bedrock] | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html | 2026-10-27 |
| [azure] | https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle | 2026-10-27 |
| [ollama] | https://docs.ollama.com/api/openai-compatibility, https://docs.ollama.com/cloud, https://ollama.com/pricing, list https://ollama.com/api/tags | 2026-10-27 |
| [lms] | https://lmstudio.ai/docs/developer/openai-compat and /docs/developer/core/authentication | 2026-10-27 |
| [llamacpp] | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md and commit "server: use port 9931 by default (#30159)", 2026-10-09 | 2026-10-27 |
| [vllm] | https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/ | 2026-10-27 |
| [jan] | https://www.jan.ai/docs/desktop/api-server | 2026-10-27 |
| [kcpp] | https://github.com/LostRuins/koboldcpp/wiki (latest release v1.123.1, 2026-10-13) | 2026-10-27 |
| [gpt4all] | https://docs.gpt4all.io/gpt4all_api_server/home.html; GitHub repo last push 2025-05-27 | 2026-10-27 |
| [hub] | pacocartones/free-llm-api-hub `data/providers.json` v2.11.0, generated 2026-10-18, facts `last_verified` 2026-10-08 (**secondary source**) | 2026-10-27 |

`cheahjs/free-llm-api-resources` was the suggested starting point, but its raw README now returns 404 on both
`main` and `master` (seen 2026-10-27), so the [hub] dataset above was used as the secondary cross-check instead.

## Summary table

Kind: **free** = renewing no-cost quota; **freemium** = renewing quota or a meaningful trial next to paid use;
**paid** = pay first (any trial is tiny or none); **local** = runs on the user's Mac or LAN.
V+T = at least one model with both vision (image input) and tool calling.

| id | Provider | Kind | API style | Base URL | Auth | Free tier (short) | V+T free model |
| --- | --- | --- | --- | --- | --- | --- | --- |
| google | Google AI Studio (Gemini) | freemium | gemini (+OpenAI compat) | https://generativelanguage.googleapis.com/v1beta | x-goog-api-key | Free tier on 3.8 Flash, 3.6 Flash, 3.5/3.1 Flash-Lite, 3 Flash preview, Gemma 4; limits only in AI Studio | gemini-3.8-flash (native computer use) |
| groq | Groq | free | openai | https://api.groq.com/openai/v1 | Bearer | 30 RPM / 1K RPD / 8K TPM / 200K TPD per model | qwen/qwen3.8-27b |
| openrouter | OpenRouter | freemium | openai | https://openrouter.ai/api/v1 | Bearer | `:free` models: 20 RPM, 50 RPD (1,000 RPD after $10 lifetime purchase) | google/gemma-4-31b-it:free, nvidia/nemotron-3.5-super-vl:free |
| cloudflare | Cloudflare Workers AI | free | openai | https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1 | Bearer | 10,000 Neurons/day | @cf/qwen/qwen3.8-27b, @cf/google/gemma-4-26b-a4b-it |
| zai | Z.ai (GLM) | freemium | openai | https://api.z.ai/api/paas/v4 | Bearer | GLM-4.7-Flash, GLM-4.5-Flash, GLM-4.6V-Flash free; limits unpublished | glm-4.6v-flash |
| mistral | Mistral AI | freemium | openai | https://api.mistral.ai/v1 | Bearer | Free mode, no card; limits only in console | mistral-small-2603, mistral-medium-3-5 |
| nvidia | NVIDIA NIM | free | openai | https://integrate.api.nvidia.com/v1 | Bearer | ~40 RPM (community figure), evaluation only | nemotron-3.5-super-vl, gemma-4-31b-it (NIM support UNVERIFIED) |
| sambanova | SambaNova Cloud | free | openai | https://api.sambanova.ai/v1 | Bearer | 20 RPM / 20 RPD / 200K TPD per model | gemma-4-31B-it (vision on SambaNova UNVERIFIED) |
| cerebras | Cerebras | freemium | openai | https://api.cerebras.ai/v1 | Bearer | $5 trial, 30 days, card required; 5 RPM | qwen-3.8-27b |
| cohere | Cohere | freemium | openai (compat) | https://api.cohere.ai/compatibility/v1 | Bearer | Trial key: 1,000 calls/month, 20 RPM, evaluation only | command-a-plus-05-2026 |
| pollinations | Pollinations | freemium | openai | https://gen.pollinations.ai/v1 | Bearer (sk_) | Quest Pollen only; every call needs a key | openai/gpt-5.4-nano, z-ai/glm-5.3-flash |
| vercel | Vercel AI Gateway | freemium | openai | https://ai-gateway.vercel.sh/v1 | Bearer | Monthly free credit (amount UNVERIFIED) on a model subset | none confirmed free |
| ovh | OVHcloud AI Endpoints | freemium | openai | https://oai.endpoints.kepler.ai.cloud.ovh.net/v1 | Bearer (optional) | Anonymous 2 RPM per IP per model | Qwen3.8-27B (billing of anonymous calls UNVERIFIED) |
| scaleway | Scaleway Generative APIs | freemium | openai | https://api.scaleway.ai/v1 | Bearer | 1M tokens one-time (secondary source) | gemma-4-26b-a4b-it |
| alibaba | Alibaba Model Studio (intl) | freemium | openai | https://dashscope-intl.aliyuncs.com/compatible-mode/v1 | Bearer | ~1M tokens per model, 90 days, Singapore | qwen3.8-flash |
| baidu | Baidu AI Studio | freemium | openai | https://aistudio.baidu.com/llm/lmapi/v3 | Bearer (access token) | 1M tokens per developer | kimi-k2.6 (UNVERIFIED on Baidu) |
| anthropic | Anthropic | paid | anthropic (+OpenAI compat) | https://api.anthropic.com/v1 | x-api-key | none | — |
| openai | OpenAI | paid | openai (Chat + Responses) | https://api.openai.com/v1 | Bearer | none | — |
| xai | xAI Grok | paid | openai | https://api.x.ai/v1 | Bearer | none confirmed | — |
| deepseek | DeepSeek | paid | openai (+Anthropic compat) | https://api.deepseek.com | Bearer | none | — |
| moonshot | Moonshot / Kimi | paid | openai | https://api.moonshot.ai/v1 | Bearer | $1 minimum recharge | — |
| minimax | MiniMax | paid | openai | https://api.minimax.io/v1 | Bearer | none found | — |
| perplexity | Perplexity Agent API | paid | custom (Responses-style) | https://api.perplexity.ai/v1 | Bearer | none | — |
| huggingface | Hugging Face router | paid | openai | https://router.huggingface.co/v1 | Bearer | free users: none; PRO $2/mo | — |
| together | Together AI | paid | openai | https://api.together.xyz/v1 | Bearer | none ($15 minimum) | — |
| fireworks | Fireworks AI | paid | openai | https://api.fireworks.ai/inference/v1 | Bearer | small trial (UNVERIFIED) | — |
| deepinfra | DeepInfra | paid | openai | https://api.deepinfra.com/v1/openai | Bearer | none | — |
| novita | Novita AI | paid | openai | https://api.novita.ai/openai | Bearer | sandbox credits only | — |
| hyperbolic | Hyperbolic | paid | openai | https://api.hyperbolic.ai/inference/v1 | Bearer | none ($5 deposit) | — |
| chutes | Chutes | paid | openai | https://llm.chutes.ai/v1 | Bearer (cpk_) | none (pay as you go) | — |
| poe | Poe | paid | openai | https://api.poe.com/v1 | Bearer | subscription points | — |
| ollama-cloud | Ollama Cloud | paid | ollama (+OpenAI compat) | https://ollama.com | Bearer | none (pay as you go) | — |
| bedrock | Amazon Bedrock | paid (complex) | openai | https://bedrock-runtime.{region}.amazonaws.com/openai/v1 | Bearer (Bedrock API key) or SigV4 | none | — |
| azure-openai | Azure OpenAI v1 | paid (complex) | openai | https://{resource}.openai.azure.com/openai/v1 | Bearer or `api-key` | none | — |
| ollama | Ollama (local) | local | ollama (+OpenAI compat) | http://localhost:11434 | none | — | depends on pulled model |
| lmstudio | LM Studio | local | openai | http://localhost:1234/v1 | none (optional token) | — | — |
| llamacpp | llama.cpp server | local | openai | http://localhost:9931/v1 (older builds 8080) | none (optional --api-key) | — | — |
| jan | Jan | local | openai | http://127.0.0.1:1337/v1 | none (optional key) | — | — |
| vllm | vLLM | local | openai | http://localhost:8000/v1 | none (optional --api-key) | — | — |
| koboldcpp | KoboldCpp | local | openai | http://localhost:5001/v1 | none | — | — |
| custom | Custom OpenAI-compatible | template | openai | user supplied | Bearer | — | — |

Not in the JSON: **GitHub Models** (retired 2026-07-30 [gh-retired]), **GPT4All** (API server still documented on
port 4891, but the repo has had no push since 2025-05-27 [gpt4all]), and the secondary-source-only providers listed
under "Other providers" below.

### Best free providers for a VM-screenshot agent (vision + tools)

1. **Google AI Studio, `gemini-3.8-flash`**. Free tier, image input, function calling, and native computer use
   (preview); 1,048,576-token input [gem-models][gem-pricing][gem-cu]. Free-tier data is used to improve Google
   products, and the numeric limits are visible only in AI Studio [gem-rl].
2. **Groq, `qwen/qwen3.8-27b`**. Free: 30 RPM, 1K RPD, 8K TPM, 200K TPD [groq-rl]. Up to 3 images per request at
   2,048 tokens each [groq-vision], with parallel tool calls [groq-tools]. The 8K TPM cap allows only about 3
   screenshots a minute.
3. **OpenRouter `:free`**: `google/gemma-4-31b-it:free` and `nvidia/nemotron-3.5-super-vl:free` both take images
   and tools [or-list]. 20 RPM, and 50 RPD rising to 1,000 RPD after a one-time $10 purchase [or-limits].
4. **Z.ai, `glm-4.6v-flash`**: a free vision model [zai]. The Hugging Face router lists it with tool support for the
   zai-org provider [hf-pricing]. Rate limits are not published.
5. **Cloudflare Workers AI**: `@cf/qwen/qwen3.8-27b` and `@cf/google/gemma-4-26b-a4b-it` both have vision and
   function calling [cf-models], within 10,000 Neurons/day [cf-pricing]. The base URL needs the account id.

Runners-up: Mistral Free mode (small and medium models have vision and tools; limits not published), NVIDIA NIM
(evaluation only, per-model support UNVERIFIED), and Cerebras `qwen-3.8-27b` (a 30-day $5 trial that needs a card).

## Native computer-use tools

| Vendor | Tool / model | How it is declared | Coordinates | Source |
| --- | --- | --- | --- | --- |
| Anthropic | `computer_toolset_20260801` (GA, no beta header) on claude-fable-5-1, claude-mythos-5-1, claude-fable-5, claude-mythos-5, claude-opus-5-5, claude-opus-5, claude-sonnet-5-5, claude-sonnet-5, claude-opus-4-8, claude-haiku-5-5 | `{"type":"computer_toolset_20260801"}` in `tools`; 17 member tools (`screenshot`, `zoom`, `left_click`, `type`, `key`, `scroll`, `wait`, ...). Each call is a `tool_use` block whose `name` is the member, with `"toolset_name":"computer"`; every `tool_result` must echo `toolset_name`. Batched actions per turn. | Screenshot pixels; the toolset rejects images over the limits, so resize and scale yourself; no display size params | [anth-cu] |
| Anthropic (earlier) | `computer_20251124` + header `anthropic-beta: computer-use-2025-11-24` (Fable/Mythos 5.x, Opus 5, Sonnet 5, Opus 4.5–4.8, Sonnet 4.6; on Bedrock also Opus/Sonnet/Haiku 5.5); `computer_20250124` + `computer-use-2025-01-24` (Sonnet 4.5, Haiku 4.5, Opus 4.1, Sonnet 4, Opus 4) | `{"type":"computer_20251124","name":"computer","display_width_px":..,"display_height_px":..}`, single `input.action` | Display size declared | [anth-cu] |
| OpenAI | GA tool `{"type":"computer"}` in the **Responses API** (models whose page lists `computer_use`: gpt-6-astra, gpt-6.1-sol, gpt-6.1-terra, gpt-6-luna, gpt-5.4-mini; the guide's examples use gpt-6.1-sol) | Model returns `computer_call` with a batched `actions[]`; reply with `computer_call_output` containing `{"type":"computer_screenshot","image_url":"data:image/png;base64,...","detail":"original"}`. For gpt-6-astra OpenAI recommends code execution instead, though `computer` stays supported. | Screenshot pixels | [oai-cu][oai-models] |
| OpenAI (legacy) | model `computer-use-preview`, tool `{"type":"computer_use_preview"}`, one `action` per call, `truncation:"auto"` required | — | — | [oai-cu-int] |
| Google | `computer_use` tool (Preview) on gemini-4-argon, gemini-3.8-flash (recommended), gemini-3.5-flash-lite, gemini-3-flash-preview; the gemini-3.6-flash model page also says "Supported (Preview)"; gemini-3.1-flash-lite says "Not supported". `gemini-2.5-computer-use-preview-10-2025` is shut down. | `computer_use` tool with an environment: `ENVIRONMENT_BROWSER` and others (browser, mobile, desktop). Actions come back as function calls (`click`, `type`, `press_key`, `hotkey`, `drag_and_drop`, `wait`, ...) with an `intent` field. | Normalised 0–999 grid; scale `x/1000*width` | [gem-cu][gem-models] |

Notes for ZCore:

- `NativeToolKind.anthropicComputer` is documented in `Tools.swift` as "computer_YYYYMMDD". The current GA
  version is `computer_toolset_20260801`, which uses a different wire format (member-named `tool_use` blocks and
  `toolset_name`). Claude 5.5 models accept only the toolset on the Claude API.
- `NativeToolKind.openAIComputer` is documented as "Responses API computer_use_preview". The GA tool type is now
  `computer`, and the preview model and tool are legacy.
- For the bundled catalogue, `nativeComputerUse` is set only on the first-party providers (anthropic, openai,
  google). Gateways (OpenRouter, Vercel, Pollinations, Perplexity) pass ordinary function tools.

## Quirk vocabulary used in `providers.json`

| Quirk | Meaning |
| --- | --- |
| `maxCompletionTokens` | Send `max_completion_tokens`, not `max_tokens` (OpenAI deprecates `max_tokens`, which is incompatible with reasoning models [oai-spec]; Kimi marks `max_tokens` deprecated [kimi]; Cerebras lists `max_completion_tokens` [cer-models]). |
| `toolsRequireResponsesAPI:<models>` | Tool calling for these models works only through `/v1/responses` [oai-models]. |
| `chatToolsOnlyWithReasoningNone:<model>` | Chat Completions function calling works only with `reasoning_effort: none` [oai-models]. |
| `computerToolType:computer` / `computerToolset:<type>` | Native computer-tool declaration to use. |
| `anthropicVersion:2023-06-01` | Required `anthropic-version` header. |
| `openAICompatAt:<url>` / `anthropicCompatAt:<url>` / `openAICompatAtV1betaOpenai` | Alternative compatible endpoint. |
| `noLogprobs`, `noMessageName` | Groq rejects `logprobs`, `logit_bias`, `top_logprobs` and `messages[].name` with HTTP 400 [groq-oai]. |
| `logprobsIgnored` | Sent but silently ignored (xAI grok-4.20+) [xai]. |
| `maxImagesPerRequest:3` | Groq Qwen 3.8: 3 images per request [groq-vision]. |
| `noParallelToolCalls[:<models>]` | Parallel tool calls unsupported (Groq gpt-oss [groq-tools], Cerebras gpt-oss [cer-models], Cohere compat [cohere]). |
| `noN`, `noLogitBias`, `reasoningEffortNoneOrHighOnly` | Cohere compatibility API limits [cohere]; Poe also requires `n`=1 [poe]. |
| `responseFormatIgnored`, `strictIgnored`, `reasoningEffortViaExtraBody` | Poe ignores `response_format`, `strict`, and `reasoning_effort` (use `extra_body`) [poe]. |
| `preserveReasoningContent` | Thinking models need each earlier assistant `reasoning_content` sent back (Kimi [kimi], MiniMax [minimax], GLM-5.3-Flash thinking settings [zai]). |
| `thinkTagsInContent` | MiniMax puts `<think>` text in `content` for several models [minimax]. |
| `responsesAPIOnly`, `chatCompletionsDeprecated` | Perplexity: Sonar Chat Completions support ended 2026-09-27; synchronous calls are being reformulated as Agent API calls [pplx]. |
| `anthropicModelsRequireMaxOutputTokens` | Perplexity Agent API rejects `anthropic/*` models without `max_output_tokens` [pplx]. |
| `accountIDInURL`, `regionInURL`, `resourceInURL` | Base URL has a placeholder the user must fill in. |
| `workspaceSubdomainRecommended`, `regionBoundKeys` | Alibaba: migrate to `https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`; keys work only in their region [ali]. |
| `responsesAPIOnlyGptOss` | Cloudflare `/v1/responses` exists only for the gpt-oss models, non-streaming [cf-oai]. |
| `freeModelsSuffix::free`, `freeModelsRotate`, `freeTierModelSubset` | Free-model conventions (OpenRouter, Vercel). |
| `freeTierTrainsOnData`, `evaluationOnly`, `cardRequired`, `phoneVerificationRequired`, `requiresPrepaidCredits` | Policy/signup flags to show in Settings. |
| `visionUnverified`, `toolsUnverified` | Model flags come from the model's own capabilities; this provider's serving support was not confirmed. |
| `textOnly` | Provider serves no image input (Hyperbolic [hyp]). |
| `apiKeyOptional`, `optionalAPIKey`, `optionalAPIToken`, `dummyKeyIfOpenAI` | Key not required (OVH anonymous, local servers); Ollama's OpenAI layer wants any non-empty key [ollama]. |
| `legacyPort:8080` | llama.cpp builds before 2026-10-09 listen on 8080 [llamacpp]. |
| `modelIsDeploymentName`, `apiKeyHeaderAlternative:api-key` | Azure: the `model` field is your deployment name; Azure also accepts an `api-key` header. |
| `sigv4Alternative`, `claudeViaBedrockMessagesAPI` | Bedrock auth and model-family notes. |
| `imageTypesJpegPngOnly` | xAI image inputs: jpg/jpeg/png, max 20 MiB [xai]. |
| `computerUseNormalized1000`, `thinkingMinimalUnsupported:<model>` | Gemini computer-use coordinates are 0–999; gemini-3.8-flash rejects thinking level `minimal` [gem-models]. |
| `concurrencyLimit200PerModel` | DeepInfra limits concurrency, not RPM [di]. |
| `userSuppliedBaseURL` | Custom template. |

---

## Free and freemium providers

### Google AI Studio / Gemini API (`google`)

- Native API: `generateContent` / `streamGenerateContent` at `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`, header `x-goog-api-key` [gem-models]. OpenAI-compatible: `https://generativelanguage.googleapis.com/v1beta/openai/` with `Authorization: Bearer <GEMINI_API_KEY>` (chat completions, tools, images, `reasoning_effort` mapped to `thinking_level`, Gemini extras via `extra_body`) [gem-oai]. Models: `GET /v1beta/models` (OpenAI compat: `/v1beta/openai/models`) [gem-oai].
- Key: https://aistudio.google.com/apikey. Docs: https://ai.google.dev/gemini-api/docs.
- Free tier [gem-pricing][gem-rl]: "Free of charge" input and output on gemini-3.8-flash, gemini-3.6-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3-flash-preview, gemini-2.5-flash/-flash-lite/-pro (2.5 access is limited to past users), and Gemma 4. gemini-4-argon is "not available on the Free tier". Usage tiers: Free (active project), Tier 1 (billing linked), Tier 2 ($100 paid + 3 days), Tier 3 ($1,000 + 30 days). Limits are per project and **no longer published**; see https://aistudio.google.com/rate-limit. RPD resets at midnight Pacific. "Used to improve our products: Yes" on the free tier.
- Secondary [hub]: no card or phone needed; since the 2026-03-23 terms, only Paid Services may serve end users in the EEA/CH/UK.
- Flagship and free model ids [gem-models]: `gemini-4-argon` (1,048,576 context, max output 65,536, up to 1,048,576 with long decode; paid), `gemini-3.8-flash` (input 1,048,576 / output 65,536; text, image, video, audio and PDF in; function calling; computer use Preview), `gemini-3.6-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite` (computer use not supported), `gemini-3-flash-preview`, `gemini-3.1-pro-preview` (paid only). Gemma on the Gemini API: `gemma-4-26b-a4b-it` and `gemma-4-31b-it`, with image understanding and function calling [gemma].
- Vision: every model above. Tools: every model above.
- Quirks: computer-use coordinates are normalised to 0–999 [gem-cu]; gemini-3.8-flash rejects thinking level `minimal` [gem-models]; Gemini 4 Argon supports only implicit caching [gem-pricing].

### Groq (`groq`)

- Base `https://api.groq.com/openai/v1`, Bearer; models `GET /openai/v1/models` [groq-models]. Key: https://console.groq.com/keys.
- Free plan [groq-rl], per model: `openai/gpt-oss-120b` and `openai/gpt-oss-20b` 30 RPM / 1K RPD / 8K TPM / 200K TPD; `qwen/qwen3.8-27b` 30 / 1K / 8K / 200K; `openai/gpt-oss-safeguard-20b` 3 RPM; Whisper 20 RPM / 2K RPD. Limits apply per organization, and cached tokens do not count. Phone verification at signup [hub].
- Models [groq-models]: production `openai/gpt-oss-120b` and `openai/gpt-oss-20b` (131,072 context, 65,536 max completion); `llama-3.1-8b-instant` and `llama-3.3-70b-versatile` are now Enterprise only (Contact Sales). Preview: `qwen/qwen3.8-27b` (131,072 context, 16,384 max completion, 20 MB files), `minimaxai/minimax-m2.7` and `meta-models/muse-spark-open` (Enterprise).
- Vision [groq-vision]: `qwen/qwen3.8-27b` (max 3 images per request, 2,048 tokens per image, 20 MB per request) and `meta-models/muse-spark-open` (Enterprise).
- Tools [groq-tools]: all hosted models; parallel tool use only on qwen/qwen3.8-27b (not on gpt-oss); JSON mode on all of them.
- Quirks [groq-oai]: `logprobs`, `logit_bias`, `top_logprobs` and `messages[].name` cause HTTP 400; temperature 0 becomes 1e-8.

### OpenRouter (`openrouter`)

- Base `https://openrouter.ai/api/v1`, Bearer; models `GET /api/v1/models` (public). Key: https://openrouter.ai/settings/keys. Docs: https://openrouter.ai/docs/api/reference/overview.
- Free limits [or-limits]: models ending in `:free` allow 20 RPM; 50 requests/day with fewer than 10 credits ever purchased, 1,000/day with 10 or more. `GET /api/v1/key` returns `free_model_daily_requests`. A negative balance blocks free models too.
- The 19 free ids seen 2026-10-27 [or-list] (v = image input, t = tools): `google/gemma-4-31b-it:free` (v t, 262,144), `google/gemma-4-26b-a4b-it:free` (v t), `nvidia/nemotron-3.5-super-vl:free` (v t, 1,000,000), `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` (v t), `thinkingmachines/inkling:free` and `inkling-small:free` (v t, 1,048,576), `dots-studio/dots-3-note-preview:free` (v t), `openrouter/free` (router, v t), `nvidia/nemotron-3-ultra-550b-a55b:free` (t), `nvidia/nemotron-3.5-lightning:free` (t), `poolside/laguna-s-2.1:free` and `laguna-xs-2.1:free` (t), `cohere/north-mini-code:free` (t), `liquid/lfm-2.5-2.6b:free` (t), `recursive/flint-v1.0:free` (t), `xingchen-agi/xing4.0-29b-a4b:free` (t), `nvidia/nemotron-3.5-content-safety:free` (v, no tools), and `google/lyria-3-clip-preview` / `google/lyria-3-pro-preview` (music, priced 0).
- Paid flagship ids on OpenRouter [or-list]: `anthropic/claude-opus-5.5`, `anthropic/claude-sonnet-5.5`, `anthropic/claude-haiku-5.5`, `anthropic/claude-fable-5.1`, `openai/gpt-6.1-terra`, `openai/gpt-6.1-sol`, `google/gemini-4-argon`, `google/gemini-3.8-flash`, `x-ai/grok-4.7`, `deepseek/deepseek-v4.1-flash`, `qwen/qwen3.8-max-prime`, `z-ai/glm-5.3`, `moonshotai/kimi-k3.1-pro`, `mistralai/mistral-large-4-0`, `minimax/minimax-m3.1-flash`.
- Secondary [hub]: the July 2026 ToS forbids reselling or building a competing service; the privacy setting for free models is separate.

### Cloudflare Workers AI (`cloudflare`)

- Base `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1`, `Authorization: Bearer {api_token}`. `/v1/chat/completions` and `/v1/embeddings` are available; `/v1/responses` exists only for gpt-oss-120b/20b and is non-streaming [cf-oai]. Token: https://dash.cloudflare.com/profile/api-tokens.
- Free [cf-pricing]: 10,000 Neurons/day on Workers Free and Workers Paid; $0.011 per 1,000 Neurons above that (Paid only). `@cf/moonshotai/kimi-k2.6`, `kimi-k2.7-code`, `@cf/zai-org/glm-5.2`, `glm-5.3`, `glm-5.3-flash` and the `@cf/deepseek-ai/deepseek-v4*` models require Workers Paid or AI Gateway credits.
- Models [cf-models]: `@cf/qwen/qwen3.8-27b` (vision + function calling, 262,144), `@cf/google/gemma-4-26b-a4b-it` (vision + function calling, 256,000), `@cf/meta/llama-4-scout-17b-16e-instruct` (vision + function calling, 131,000), `@cf/openai/gpt-oss-120b` (function calling, 128,000), `@cf/zai-org/glm-4.7-flash` (function calling, 131,072), `@cf/meta/llama-3.3-70b-instruct-fp8-fast` (function calling, 24,000), `@cf/mistralai/mistral-small-3.1-24b-instruct` (function calling, 128,000; this page does not mark it vision).
- Models endpoint: not set in the JSON. Cloudflare's model search API lives at a different path (UNVERIFIED for the `/ai/v1` prefix).

### Z.ai / Zhipu GLM (`zai`)

- Base `https://api.z.ai/api/paas/v4`, Bearer [zai]. `GET /models` answers (401 without a key, seen 2026-10-27). Key: https://z.ai/manage-apikey/apikey-list. Since 2026-10-16, standard API keys and GLM Coding Plan keys are managed separately (docs.z.ai/llms.txt).
- Free [zai]: `GLM-4.7-Flash` and `GLM-4.5-Flash` (text) and `GLM-4.6V-Flash` (vision) are listed as Free for input, cached input and output. RPM/TPM are not published.
- Paid flagships [zai]: `glm-5.3` ($1.4 / $4.4 per M tokens, 1M context), `glm-5.3-flash` (multimodal: video, image, text and file in; 1M context; function calling), `GLM-5.3-FlashX`, `GLM-5.2`, `GLM-4.6V`.
- API ids are lowercase (`glm-5.3` appears in the quick-start example). Free-model ids are `glm-4.7-flash`, `glm-4.5-flash` and `glm-4.6v-flash` per [hub] and the HF router (`zai-org/GLM-4.6V-Flash`, image + tools) [hf-pricing].
- Quirk: GLM-5.3-Flash `thinking.type` supports only `enabled`; recommended settings are `temperature 1`, `top_p 0.95`, `reasoning_effort max` [zai].

### Mistral AI (`mistral`)

- Base `https://api.mistral.ai/v1`, Bearer; `GET /v1/models`. Key: https://console.mistral.ai/api-keys (redirects to login).
- Free [mis-free]: "Free mode: API access is enabled by default with no credit card required. Usage and rate limits apply." Free mode is the default state for new accounts. Per-model limits appear only in the Admin Panel (API > Limits). Secondary [hub]: in Free mode Mistral may train on inputs and outputs unless you opt out.
- Models [mis-models]: `mistral-large-4` / `mistral-large-4-0` (1M context, text + image, function calling), `mistral-medium-3-5` / `mistral-medium-latest` (256k, text + image, function calling), `mistral-small-2603` / `mistral-small-latest` (Mistral Small 4, 256k, text + image, function calling), `ministral-14b-2512` / `ministral-14b-latest` (256k, text + image, function calling). Mistral also hosts Z.ai GLM 5.3 and 5.3 Flash.

### NVIDIA NIM / build.nvidia.com (`nvidia`)

- Base `https://integrate.api.nvidia.com/v1`, Bearer; `GET /v1/models` is public (85 models on 2026-10-27) [nim-list]. Key: https://build.nvidia.com.
- Free [nim-forum]: free for NVIDIA Developer Program members. About **40 RPM** is the commonly cited cap; NVIDIA staff say the limit depends on model and load and is shown in the build.nvidia.com navigation bar. "We no longer use a credit-based system" (NVIDIA staff, 2025-09-10). Evaluation only, not production; phone verification [hub]. **UNVERIFIED** against an official limits page.
- Notable ids [nim-list]: `nvidia/nemotron-3.5-super-vl-120b-a12b`, `nvidia/nemotron-3-ultra-550b-a55b`, `google/gemma-4-31b-it`, `moonshotai/kimi-k2.6`, `z-ai/glm-5.3`, `z-ai/glm-5.3-flash`, `deepseek-ai/deepseek-v4.1-flash`, `minimaxai/minimax-m3.1-flash`, `openai/gpt-oss-20b`, `meta/llama-3.2-90b-vision-instruct`, `stepfun-ai/step-5-preview`. Per-model vision and tool support on NIM is **UNVERIFIED**; the JSON flags reflect what the models themselves can do.

### SambaNova Cloud (`sambanova`)

- Base `https://api.sambanova.ai/v1`, Bearer; `GET /v1/models` [samba-rl]. Key: https://cloud.sambanova.ai/apis.
- Free Tier (no payment method linked) [samba-rl]: `DeepSeek-V3.1`, `Meta-Llama-3.3-70B-Instruct` and `gpt-oss-120b` at 20 RPM / 20 RPD / 200,000 TPD each; previews `DeepSeek-V3.2` and `gemma-4-31B-it` at the same limits. Developer Tier: 60–240 RPM, 12K–48K RPD, 20M tokens/day. The plans page contradicts the docs on whether a card is needed [hub].
- Model list [samba-rl]: also `MiniMax-M3.1-Flash` (1,048,576 context, not on the free table). Vision and tool support on SambaNova are **UNVERIFIED**.

### Cerebras (`cerebras`)

- Base `https://api.cerebras.ai/v1`, Bearer; public list at `https://api.cerebras.ai/public/v1/models` [cer-models]. Key: https://cloud.cerebras.ai.
- Free Trial [cer-rl]: "$5 in free credits after adding a verified payment method", expiring 30 days after grant. "No... permanently free tier." Per model: 5 RPM, 30K uncached TPM, 90K total TPM, 1M TPH, 1M TPD.
- Models [cer-models]: `gpt-oss-120b` (65k free / 131k paid context; tools; no vision; no parallel tool calls; max completion 40,960) and `qwen-3.8-27b` (64k / 128k; vision, tools and parallel tools; max completion 32,768). Supports `max_completion_tokens`.

### Cohere (`cohere`)

- OpenAI-compatible base `https://api.cohere.ai/compatibility/v1`, Bearer [cohere]. Key: https://dashboard.cohere.com/api-keys.
- Trial keys [cohere]: "limited to 1,000 API calls a month"; 20 req/min per chat model. Evaluation only.
- Models [cohere]: `command-a-plus-05-2026` (vision + agentic + reasoning; context 192,000 per [or-list]), `command-a-03-2025` (tools, 256K), `command-a-vision-07-2025` (image input; tool support not stated, so the JSON says false), `command-a-reasoning-08-2025`, `command-r7b-12-2024`, `north-mini-code-1.0`.
- Compat API: `reasoning_effort` accepts only `none` and `high`; `parallel_tool_calls`, `n`, `logit_bias`, `top_logprobs`, `modalities`, `audio` and `store` are unsupported [cohere].

### Pollinations (`pollinations`)

- Base `https://gen.pollinations.ai` (OpenAI SDK base `https://gen.pollinations.ai/v1`), Bearer `sk_...` key from https://enter.pollinations.ai/keys [poll]. The same host serves `/v1/chat/completions`, a stateless `/v1/responses`, and Anthropic `/v1/messages`.
- Free: generation always needs a key and spends Pollen. Free Pollen comes from Quests and works only on models with `paid_only: false` [poll][hub]. `sk_` keys have no rate limit; legacy raw `pk_` keys allow 1 Pollen per IP per hour. Model listing needs no key.
- Non-paid-only vision + tools models [poll]: `openai/gpt-5.4-nano` (400k), `openai/gpt-5.4-mini`, `openai/gpt-6-luna`, `openai/gpt-6.1-sol`, `openai/gpt-6.1-terra`, `z-ai/glm-5.3-flash`, `moonshotai/kimi-k2.6`, `moonshotai/kimi-k3`, `deepseek/deepseek-v4.1-flash`, `minimax/minimax-m3`, `x-ai/grok-4.3`.

### Vercel AI Gateway (`vercel`)

- Base `https://ai-gateway.vercel.sh/v1`, Bearer; `GET /v1/models` is public (496 entries, with `vision` and `tool-use` tags) [vercel].
- Free [vercel]: every team has a free tier with a monthly free credit on a subset of models ("Free Tier models"), with lower per-model rate limits. Buying credits ends the free credit. BYOK only on the paid tier. The **amount** is not on the current page; web search attributes "$5 every 30 days" to Vercel docs (**UNVERIFIED**).
- Models tagged `free`: `poolside/laguna-s-2.1-free`, `reflection/beam-free`, `convaiinnovations/laya(-free)`. Which models count as "Free Tier" is not in the public list (**UNVERIFIED**).

### OVHcloud AI Endpoints (`ovh`)

- Base `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1`, optional Bearer [ovh][hub].
- Limits [ovh]: "Anonymous: 2 requests per minute, per IP and per model. Authenticated with an API access key: 400 requests per minute, per PCI project and per model." Whether anonymous calls to priced chat models are billed is **UNVERIFIED**. The $0 models are Qwen3Guard, SDXL, Riva TTS and Whisper [ovh][hub].
- LLMs [ovh]: `Qwen3.8-27B` and `Qwen3.6-27B` (262,144), `Qwen3.5-397B-A17B`, `Qwen3.5-9B`, `gpt-oss-120b` and `gpt-oss-20b` (131,072), `Mistral-Small-3.2-24B-Instruct-2506`, `Meta-Llama-3_3-70B-Instruct`, `Qwen2.5-VL-72B-Instruct`, `Mistral-Nemo-Instruct-2407`.

### Scaleway Generative APIs (`scaleway`)

- Base `https://api.scaleway.ai/v1`, Bearer [hub]. Key: https://console.scaleway.com/iam/api-keys. Scaleway's docs returned HTTP 403 to automated fetches on 2026-10-27, so these facts are **secondary** ([hub], verified 2026-10-08).
- Free: 1,000,000 tokens plus 60 min of Whisper, one-time and not time-limited. With a payment method, 300 RPM / 200K TPM per model. Does not train on API data.
- Model ids [hub]: `llama-3.3-70b-instruct`, `qwen3-235b-a22b-instruct-2507`, `mistral-small-3.2-24b-instruct-2506`, `gpt-oss-120b`, `gemma-4-26b-a4b-it`, `qwen3-coder-30b-a3b-instruct`.

### Alibaba Cloud Model Studio, international (`alibaba`)

- OpenAI-compatible [ali]: the docs now recommend workspace domains, `https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` (Singapore), with Virginia, Hong Kong and Tokyo variants, "Migrate from https://dashscope-intl.aliyuncs.com". The JSON keeps the legacy `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` because it needs no workspace id. Keys are region-bound (a cross-region key gives 401). Bearer.
- Free quota [ali]: granted on first activation in Singapore for International-scope models; "valid for 90 days"; real-time inference only; one per account. "Typically 1,000,000 tokens per model" [hub].
- Recommended models [ali]: `qwen3.8-max` (complex reasoning; visual understanding), `qwen3.7-plus` (balanced; visual understanding), `qwen3.8-flash` (fast), `qwen3.8-omni-flash` (visual understanding), plus third-party `deepseek-v4-pro-0813`, `deepseek-v4.1-flash`, `glm-5.2`, `kimi-k3`, `MiniMax-M2.5`. Tool-use tags are from [vercel]; contexts from [or-list].

### Baidu AI Studio / ERNIE (`baidu`)

- Base `https://aistudio.baidu.com/llm/lmapi/v3`; pass the AI Studio Access Token as the OpenAI `api_key` (Bearer) [baidu]. Token page: https://aistudio.baidu.com/account/accessToken.
- Free [baidu]: "Each developer gets a free quota of 1 million Tokens". Numeric rate limits are not published.
- Models (public list, 59 ids) [baidu]: `ernie-5.1`, `ernie-5.0-thinking-preview`, `ernie-x1.1-preview`, `ernie-4.5-turbo-vl` (vision), `ernie-4.5-vl-28b-a3b-thinking` (vision), `kimi-k2.6`, `deepseek-v4-pro`, `deepseek-v4-flash`, `glm-5.2`, `qwen3.5-27b`, ... The doc's function-calling sections list `ernie-5.1`, `ernie-5.0-thinking-preview`, `ernie-x1.1-preview`, `ernie-x1-turbo(-32k)`, `deepseek-r1` and `deepseek-v3`, and the two sections disagree.
- Baidu Qianfan (paid): `https://qianfan.baidubce.com/v2`, model `ernie-5.1` (third-party sources, **UNVERIFIED**).

---

## Paid providers

### Anthropic (`anthropic`)

- Native Messages API `POST https://api.anthropic.com/v1/messages`, headers `x-api-key` and `anthropic-version: 2023-06-01` [anth-cu]; `GET /v1/models` returns `max_input_tokens`, `max_tokens` and `capabilities` [anth-models]. Key: https://platform.claude.com/settings/keys.
- OpenAI SDK compatibility at `https://api.anthropic.com/v1/` [anth-oai]: `strict` ignored, `response_format` ignored, system/developer messages hoisted into one `system` field, no prompt caching, audio stripped.
- Current models [anth-models], all with text and image input, vision, tool use, 1M context and 128K max output: `claude-fable-5-1` ($10/$50), `claude-opus-5-5` ($4/$20, "start with" this one), `claude-sonnet-5-5` ($2/$10), `claude-haiku-5-5` (from $0.10/$0.50). Legacy but available: `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`, `claude-sonnet-5`, `claude-sonnet-4-6`, `claude-haiku-4-5`. Bedrock ids are `anthropic.claude-opus-5-5` etc.
- Free: none. New organizations may start in an Evaluation tier with lower limits [anth-rl].
- Computer use: see the table above.

### OpenAI (`openai`)

- Base `https://api.openai.com/v1`, Bearer; Chat Completions and Responses; `GET /v1/models`. Key: https://platform.openai.com/api-keys.
- Featured models [oai-models]: `gpt-6-astra` (flagship, $10/$50, 1,050,000 context, 128,000 max output, text + image), `gpt-6.1-sol` ($2 input; "Tool calling requires the Responses API"), `gpt-6.1-terra` ($1 input; "visual reasoning, precise computer use"; tool calling requires Responses), `gpt-6-luna` ($0.1 input; Chat Completions function calling only with `reasoning_effort: none`). All four list `computer_use` among their Responses tools. Also `gpt-6-sol`, the `gpt-5.6-*` family, `gpt-5.5`, `gpt-5.4-mini` (400,000 context, computer use), `gpt-oss-120b` and `gpt-oss-20b`, and the legacy `computer-use-preview`.
- Quirk: send `max_completion_tokens`; `max_tokens` is deprecated and incompatible with reasoning models [oai-spec].
- Free: none. The "Free" usage tier (users in allowed geographies, $100/month cap) is a spending ceiling, not free tokens [oai-rl].

### xAI Grok (`xai`)

- Base `https://api.x.ai/v1`, Bearer. Key: https://console.x.ai.
- Models [xai]: `grok-4.7` (500k; "the most capable model we've built"), `grok-4.6`, `grok-4.5`, `grok-4.3` (1M), `grok-4.20-0309-reasoning` / `-non-reasoning` (1M), `grok-build-0.1` (256k), `grok-4.20-multi-agent-0309`. Image inputs: max 20 MiB, jpg/png only, any number. `logprobs` is ignored on grok-4.20+. Vision and tools flags come from [or-list].
- Free credits: reports conflict (a $25 signup credit and $150/month data-sharing credit may have ended in 2026), so **UNVERIFIED**.

### DeepSeek (`deepseek`)

- Base `https://api.deepseek.com` (OpenAI format), `https://api.deepseek.com/anthropic` (Anthropic format), Bearer [deepseek]. Key: https://platform.deepseek.com/api_keys.
- Models [deepseek]: `deepseek-flash` (served by DeepSeek-V4.1-Flash-1017; 1M context, max output 384K, JSON, tools, **vision**) and `deepseek-v4-pro` (V4-Pro-0813; JSON, tools, no vision). The legacy names `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are still accepted and routed to V4.1-Flash-1017.
- Free: none documented.

### Moonshot AI / Kimi (`moonshot`)

- Base `https://api.moonshot.ai/v1`, Bearer [kimi]. Key: https://platform.kimi.ai/console/api-keys.
- Models [kimi]: `kimi-k3.1-pro`, `kimi-k3.1-pro-highspeed`, `kimi-k3`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k2.6`. Image and video input go in `image_url` / `video_url` parts. Contexts from [or-list]: k3.1-pro and k3 1,048,576; k2.7-code and k2.6 262,144.
- Quirks: `max_tokens` is deprecated in favour of `max_completion_tokens`; thinking models need `reasoning_content` preserved; on kimi-k2.7-code `thinking.keep` is fixed at `"all"`, and `"disabled"` is rejected on some models [kimi].
- Free: $1 minimum recharge to start; a $5 voucher after $5 cumulative recharge [kimi-limits]. Tier-0 limits are **UNVERIFIED**.

### MiniMax (`minimax`)

- Base `https://api.minimax.io/v1`, Bearer [minimax]. Models: `MiniMax-M3.1-Flash` and `MiniMax-M3` (1,000,000 context, text/image/video in; images take `detail` low/default/high), plus legacy `MiniMax-M2.7` and `MiniMax-M2.5`.
- Quirks: append the full assistant message, including `tool_calls`; M3.1-Flash returns `reasoning_content` separately, which must be preserved; several models put `<think>` text in `content` [minimax].

### Perplexity (`perplexity`)

- The Agent API follows the OpenAI Responses format: `POST https://api.perplexity.ai/v1/agent`, with `/v1/responses` as an alias; `GET /v1/models` [pplx]. "Sonar Chat Completions support ended on September 27, 2026": synchronous and streaming requests are being reformulated as Agent API requests, and async Sonar is unsupported. `apiStyle` is therefore `custom`.
- Models [pplx]: `perplexity/sonar` plus third-party `anthropic/claude-*`, `openai/gpt-6*`, `google/gemini-*`, `xai/grok-*`, `perplexity/glm-5.3`, `perplexity/kimi-k3` and others. `anthropic/*` models require `max_output_tokens`.

### Hugging Face Inference Providers (`huggingface`)

- Base `https://router.huggingface.co/v1`, Bearer HF token [hf-pricing]. Free users get **no** monthly credits; PRO and Team/Enterprise get $2.00/month. 138 router models; vision + tools models include `Qwen/Qwen3.8-27B`, `google/gemma-4-31B-it`, `zai-org/GLM-5.3-Flash`, `moonshotai/Kimi-K3` and `deepseek-ai/DeepSeek-V4.1-Flash`. No `is_free` provider on 2026-10-27.

### Together AI (`together`)

- Base `https://api.together.xyz/v1` [together]. "Together AI does not currently offer free trials... requires a minimum $15 credit purchase" ($5 after the first purchase). Vision models: `moonshotai/Kimi-K3`, `nvidia/NVIDIA-Nemotron-3.5-Super-VL`, `Qwen/Qwen3.5-9B`. Function calling: Yes on the chat models listed. `Prism-ML/Ternary-Bonsai-27B` is priced Free.

### Fireworks AI (`fireworks`)

- Base `https://api.fireworks.ai/inference/v1`; ids look like `accounts/fireworks/models/glm-5p3-flash`, `accounts/fireworks/models/glm-5p3` and `accounts/fireworks/models/kimi-k3` [fw]. Prepaid credits with spend tiers. Secondary [hub]: $1 trial credit and 10 RPM without a payment method (**UNVERIFIED**).

### DeepInfra (`deepinfra`)

- Base `https://api.deepinfra.com/v1/openai` [di]. 200 concurrent requests per model, not an RPM cap. 53 `vision` models, including `Qwen/Qwen3.8-27B`, `google/gemma-4-31B-it`, `zai-org/GLM-5.3-Flash`, `moonshotai/Kimi-K3`, `deepseek-ai/DeepSeek-V4.1-Flash` and `anthropic/claude-sonnet-5-5`. No free tier.

### Novita AI (`novita`)

- Base `https://api.novita.ai/openai` (novita.ai/docs/llms.txt). 99 models; vision + function-calling entries include `qwen/qwen3.8-27b`, `zai-org/glm-5.3-flash`, `google/gemma-4-31b-it` and `moonshotai/kimi-k3`. Promotional credits apply to Agent Sandbox, not Model API [hub].

### Hyperbolic (`hyperbolic`)

- Base `https://api.hyperbolic.ai/inference/v1` [hyp]. "Personal accounts on the Free Tier can't use inference"; a one-time $5 deposit is required (HTTP 403 `inference_requires_pro`). Text models only: "vision ... models from the previous inference API aren't available". Ids: `glm-5.3-flash`, `glm-5.3`, `kimi-k3`, `minimax-m3`, `deepseek-v4.1-flash`, `deepseek-v4-flash-0731`, `nemotron-3-ultra-550b-a55b`, `step-5-preview`, `mimo-v2.6-flash`. Tool support is not stated.

### Chutes (`chutes`)

- Base `https://llm.chutes.ai/v1`, `Authorization: Bearer cpk_...`; public `GET /v1/models` [chutes]. Pay as you go, "no subscription and no minimum commitment"; no free tier listed (third-party reports of free daily quotas conflict, so **UNVERIFIED**/likely obsolete). TEE models with image input and tools: `Qwen/Qwen3.8-27B-TEE`, `google/gemma-4-31B-turbo-TEE`, `moonshotai/Kimi-K3-TEE`, `moonshotai/Kimi-K2.6-TEE`.

### Poe (`poe`)

- Base `https://api.poe.com/v1`, Bearer key from https://poe.com/api/keys [poe]. Uses subscription points, with add-on points for sale; 500 RPM. Tools and image inputs are supported; `response_format`, `strict` and `reasoning_effort` are ignored; `n` must be 1. Example ids: `Claude-Opus-4.7`, `Claude-Sonnet-4.6`, `Gemini-3.1-Pro`, `GPT-5.4`, `Grok-4`.

### Ollama Cloud (`ollama-cloud`)

- Native `https://ollama.com/api/chat` with Bearer `OLLAMA_API_KEY`; OpenAI compat at `https://ollama.com/v1` (no stateful Responses) [ollama]. Pricing page: "Pay as you go" $0 plan billed per token with 3 concurrent requests; Pro $20/mo includes $60 credits; Max $100/mo. **No free allowance** is listed on 2026-10-27; [hub] (2026-10-08) still described starter credits, so this changed recently.
- Cloud models with vision + tools [ollama]: `gemma4:31b`, `kimi-k3`, `kimi-k2.6`, `glm-5.3-flash`, `deepseek-v4.1-flash`, `minimax-m3`, `minimax-m3.1-flash`, `mistral-large-4`, `muse-spark-open`.

### Amazon Bedrock (`bedrock`), complex

- OpenAI Chat Completions at `https://bedrock-runtime.{region}.amazonaws.com/openai/v1/chat/completions` (recommended) or `https://bedrock-mantle.{region}.api.aws/v1/chat/completions`, authenticated with an **Amazon Bedrock API key** as `Authorization: Bearer` or with AWS SigV4 [bedrock]. The example model is `openai.gpt-oss-120b-1:0`. Claude on Bedrock uses Bedrock's Messages-API endpoint with ids `anthropic.claude-opus-5-5` etc. [anth-models]; its exact URL was not read (**UNVERIFIED**). On Bedrock, Claude Opus/Sonnet/Haiku 5.5 accept the beta `computer_20251124` tool [anth-cu].

### Azure OpenAI v1 API (`azure-openai`), complex

- Base `https://YOUR-RESOURCE-NAME.openai.azure.com/openai/v1/`; `api-version` is no longer required; works with the plain `OpenAI()` client using `api_key` (Bearer) or Entra tokens [azure]. The `model` field is the user's deployment name, so the JSON ships no model list.

---

## Local servers

| id | Server | Base URL | Auth | Models endpoint | Notes |
| --- | --- | --- | --- | --- | --- |
| ollama | Ollama | native `http://localhost:11434` (`/api/chat`, `/api/tags`); OpenAI `http://localhost:11434/v1/` | none; OpenAI SDKs need a dummy key ("required but ignored") | `/api/tags` | `/v1/chat/completions` supports vision (`image_url`) and tools; `/v1/responses` also exists [ollama] |
| lmstudio | LM Studio | `http://localhost:1234/v1` | none by default; optional API tokens (LM Studio 0.4.0+) | `/v1/models` | also `/v1/responses` and a native `/api/v1/chat` [lms] |
| llamacpp | llama.cpp `llama-server` | `http://localhost:9931/v1` | none; optional `--api-key` | `/v1/models` (now reports input/output modalities) | **Default port changed from 8080 to 9931 on 2026-10-09** (PR #30159); Docker examples still map 8080. Tool-call support (and `parallel_tool_calls`) depends on the model's Jinja chat template [llamacpp] |
| jan | Jan | `http://127.0.0.1:1337/v1` | optional key set in Configuration > API Key | `/v1/models` | [jan] |
| vllm | vLLM | `http://localhost:8000/v1` | optional `--api-key` / `VLLM_API_KEY` (does not protect every endpoint) | `/v1/models` | [vllm] |
| koboldcpp | KoboldCpp | `http://localhost:5001/v1` | none (`--password` protects only save/load) | `/v1/models` | OpenAI-compatible `/v1/chat/completions` [kcpp] |
| — | GPT4All | `http://localhost:4891/v1` | none | `/v1/models` | Not in JSON: repo inactive since 2025-05-27 [gpt4all] |

## Other providers (secondary source only, not in the JSON)

From [hub] (facts verified by the hub on 2026-10-08, not re-checked here; all **UNVERIFIED** by this research):
SiliconFlow (`https://api.siliconflow.cn/v1`, permanently free small models on the China site, needs Chinese real-name
verification), ModelScope (`https://api-inference.modelscope.cn/v1`, daily "Magicubes", needs an Alibaba real-name
account, non-commercial), Nebius Token Factory (`https://api.tokenfactory.nebius.com/v1`, $1 trial for 30 days, card),
Baseten (`https://inference.baseten.co/v1`), AI21 (`https://api.ai21.com/studio/v1`, $10 for 3 months), IBM watsonx,
Arli AI (`https://api.arliai.com/v1`, 5 requests per 2 days per model), Typhoon (`https://api.opentyphoon.ai/v1`, free
Thai models; the public list shows `typhoon-v2.5-30b-a3b-instruct`), Upstage (`https://api.upstage.ai/v1`, $10 credit),
W&B / CoreWeave Inference (`https://api.inference.wandb.ai/v1`), Tencent Hunyuan TokenHub
(`https://tokenhub.tencentmaas.com/v1`, 1M tokens per model, until 2026-12-31), and Poolside
(`https://inference.poolside.ai/v1`, free developer key for Laguna models).

## Could not verify

- Google's numeric free-tier RPM/TPM/RPD (only in AI Studio after sign-in).
- Mistral Free mode limits, and which models it covers.
- NVIDIA NIM's official rate limit, and per-model vision/tool support on NIM.
- Vercel AI Gateway's free credit amount, and which models are "Free Tier".
- Z.ai rate limits for the free Flash models; the free-model ids are confirmed in lowercase only via [hub] and the HF router.
- Whether OVH bills anonymous calls to priced models.
- Scaleway (docs blocked automated fetches): all facts come from [hub].
- Fireworks trial credit, xAI free credits, Kimi tier-0 limits, Chutes free quota (likely gone).
- Vision on SambaNova `gemma-4-31B-it`, Baidu `kimi-k2.6`, OVH and Scaleway models; tool support on Hyperbolic, OVH, Scaleway and Baidu (flagged in quirks).
- Bedrock's Claude Messages-API URL, and Baidu Qianfan's paid endpoint.
