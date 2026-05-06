interface JsonViewProps {
  value: unknown;
}

export function JsonView({ value }: JsonViewProps) {
  return (
    <pre className="json-view">{JSON.stringify(value, null, 2)}</pre>
  );
}

