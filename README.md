# Z Computer

A personal AI computer for the Mac: an App Store app with a built-in virtual machine (boot any Linux ISO, or a macOS guest on Apple silicon), an AI agent that can see and control that machine, a personal memory library, a terminal, a live "what is the agent doing" panel, and a team mode where several agents share one machine.

Works with your own API key for the major providers (Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral, Moonshot, Z.ai, Qwen, MiniMax...), with the free tiers (Groq, Cerebras, Google AI Studio, OpenRouter free models, GitHub Models, Cloudflare, NVIDIA NIM, Mistral free, ...) as first-class citizens, and with small local models (MLX on-device, Apple Foundation Models, Ollama / LM Studio / llama.cpp).

Built with Swift 6 / SwiftUI / Virtualization.framework. See `docs/` for the architecture and the research behind the provider catalogue.
