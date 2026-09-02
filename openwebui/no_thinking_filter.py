"""
title: No Thinking
author: local
description: Išjungia Qwen3.8 mąstymą per užklausą (chat_template_kwargs enable_thinking=false). Toggle Open WebUI'e — greitas per-chat jungiklis be vLLM perkrovimo.
required_open_webui_version: 0.4.0
version: 0.1.0
license: MIT
"""
# ĮDIEGIMAS: Admin Panel -> Functions -> Create -> įklijuok -> Save -> įjunk (Global arba per modelį).
# Kai ĮJUNGTAS: kiekviena užklausa gauna enable_thinking=false -> modelis nemąsto.
# Kai IŠJUNGTAS: normalus (mąsto). Alternatyva: kortelės 'Non-thinking' režimas (serverio lygyje).

from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        enabled: bool = Field(default=True, description="Išjungti mąstymą (enable_thinking=false)")

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, **kwargs) -> dict:
        if not self.valves.enabled:
            return body
        try:
            ck = body.get("chat_template_kwargs") or {}
            ck["enable_thinking"] = False
            body["chat_template_kwargs"] = ck
        except Exception:
            pass
        return body
