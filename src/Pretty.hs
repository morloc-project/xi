module Pretty (
  prettyTerm
) where

import TypedExpr
import Type
import Expr

import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.Terminal
import Data.Text.Prettyprint.Doc.Render.Terminal.Internal

typeStyle = SetAnsiStyle {
      ansiForeground  = Just (Vivid, Green) -- ^ Set the foreground color, or keep the old one.
    , ansiBackground  = Nothing             -- ^ Set the background color, or keep the old one.
    , ansiBold        = Nothing             -- ^ Switch on boldness, or don’t do anything.
    , ansiItalics     = Nothing             -- ^ Switch on italics, or don’t do anything.
    , ansiUnderlining = Just Underlined     -- ^ Switch on underlining, or don’t do anything.
  } 

cast :: Pretty a => a -> Doc AnsiStyle -> Doc AnsiStyle
cast t d = d <> ":" <> (annotate typeStyle (pretty t))

prettyTerm :: TypedExpr -> Doc AnsiStyle
prettyTerm (EVar n t) = cast t (pretty n)
prettyTerm (EApp e1 e2 t) = cast t . parens $ prettyTerm e1 <+> prettyTerm e2
prettyTerm (ELam (Arg n _) e t) = cast t . parens . hsep $  ["\\", pretty n, ".", prettyTerm e]
prettyTerm (ELet n e1 e2 t) = cast t . parens . hsep $ ["let", pretty n, "=", prettyTerm e1, "in", prettyTerm e2]

instance Pretty Type where
  pretty (TVar n) = pretty n
  pretty t@(TLam t1 t2) = case fromFunction t of
    Just (a, b) -> parens $ pretty a <+> "->" <+> pretty b
    Nothing -> parens $ pretty t1 <+> pretty t2
