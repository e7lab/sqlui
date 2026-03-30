local picker = require("sqlui.ui.picker")

local M = {}

function M.open()
  local items = {
    {
      key = "<leader>ss",
      title = "Menu SQL",
      summary = "Abre o menu principal para executar ou exportar SQL.",
      details = {
        "Modo normal: trabalha com o arquivo inteiro.",
        "Modo visual: trabalha com a selecao atual.",
        "Acoes: executar, executar na ultima conexao, exportar CSV, exportar XLSX.",
      },
    },
    {
      key = "<leader>sb / <leader>sl",
      title = "Selecionar conexao",
      summary = "Seleciona a conexao ativa compartilhada entre usql e sqls.",
      details = {
        "Usa o mesmo seletor visual das conexoes salvas.",
        "Permite criar, editar, renomear e remover conexoes.",
      },
    },
    {
      key = "<leader>sa",
      title = "Browser SQL",
      summary = "Abre schemas, tabelas, views, functions e procedures.",
      details = {
        "Suporta cache local por conexao.",
        "Atalhos internos: <Space>t/v/f/p, <Space>n/b, <Space>s.",
        "<Enter> em tabelas/views abre a visualizacao de dados.",
        "Use <C-y> para inserir o nome do objeto no buffer.",
        "Setas e PageUp/PageDown navegam na lista e preview.",
      },
    },
    {
      key = ":SqlUiViewData",
      title = "Visualizar dados",
      summary = "Abre visualizacao paginada de dados para tabela/view.",
      details = {
        "Atalhos: ]p / [p, ff, fc, fo, r, q.",
        "Suporta filtros multiplos com ';'.",
        "Exemplo: status=ativo;nome~joao",
      },
    },
    {
      key = "<leader>sr",
      title = "Ultima conexao",
      summary = "Executa o SQL atual usando a ultima conexao utilizada.",
      details = {
        "Modo normal: arquivo inteiro na ultima conexao.",
        "Modo visual: selecao atual na ultima conexao.",
      },
    },
    {
      key = "<leader>sh",
      title = "Historico SQL",
      summary = "Abre o historico de consultas executadas.",
      details = {
        "Mostra horario, conexao e primeira linha da query.",
      },
    },
    {
      key = "<leader>se",
      title = "Exportar CSV",
      summary = "Exporta o SQL atual ou a selecao para CSV.",
      details = {
        "Modo normal: arquivo inteiro.",
        "Modo visual: selecao atual.",
      },
    },
    {
      key = "<leader>sx",
      title = "Exportar XLSX",
      summary = "Exporta o SQL atual ou a selecao para XLSX.",
      details = {
        "Modo normal: arquivo inteiro.",
        "Modo visual: selecao atual.",
      },
    },
    {
      key = ":SqlUiBuildCache",
      title = "Gerar cache",
      summary = "Gera o cache local do browser SQL para uma conexao salva.",
      details = {
        "Melhora muito a navegacao em bancos grandes.",
        "<leader>sc usa a conexao atual (ou a ultima conexao salva).",
        "Mostra progresso por schema durante a geracao.",
      },
    },
    {
      key = ":SqlUiClearCache",
      title = "Limpar cache",
      summary = "Remove o cache local do browser SQL de uma conexao.",
      details = {
        "Util quando o schema do banco mudou.",
      },
    },
  }

  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if not has_telescope then
    picker.select(items, {
      prompt = "Guia sqlui",
      format_item = function(item)
        return string.format("%s  %s", item.key, item.title)
      end,
    }, function() end)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")

  pickers
    .new(require("telescope.themes").get_dropdown({
      prompt_title = "Guia sqlui",
      layout_strategy = "horizontal",
      layout_config = {
        width = 0.82,
        height = 0.68,
        preview_width = 0.56,
      },
    }), {
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local display = string.format("%s  %s", item.key, item.title)
          return {
            value = display,
            item = item,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local item = entry.item
          local lines = {
            item.key,
            item.title,
            "",
            item.summary,
            "",
            "Detalhes:",
          }
          for _, detail in ipairs(item.details or {}) do
            table.insert(lines, "- " .. detail)
          end
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "txt"
        end,
      }),
    })
    :find()
end

return M
